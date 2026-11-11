import { link, lstat, mkdir, rename, rm } from "node:fs/promises";
import { isNotFound, makeTempDir, writeTextFile } from "../platform/fs.ts";
import { basename, join } from "node:path";
import {
  type PackageRequest,
  validatePackageRequest,
} from "../domain/package_request.ts";
import { resolveUvExecutable } from "../platform/uv.ts";
import {
  applicationPaths,
  createApplicationLauncher,
} from "./application_layout.ts";
import {
  type ClientArchive,
  clientArchivePath,
  createClientArchive,
} from "./client_archive.ts";
import { findInstalledEntryPoint } from "./entry_point.ts";
import { type ProcessEvents, runInvocation } from "./process.ts";
import { selectPythonDistribution } from "./python_distribution.ts";
import {
  materializePythonRuntime,
  PythonRuntimeError,
} from "./python_runtime.ts";
import { writeSupplyChainFiles } from "./supply_chain.ts";
import {
  buildGitRootInstallInvocation,
  buildTargetInstallInvocation,
  buildTargetRequirementsInvocation,
} from "./target_install.ts";
import {
  readWheelRequirements,
  requirePortableGitWheel,
} from "./wheel_metadata.ts";
import { BUNDLR_VERSION } from "../version.ts";

export interface PackageResult {
  readonly artifactPath: string;
  readonly target: string;
}

export interface PackagedTarget extends PackageResult, ClientArchive {}

export async function packageTargets(
  request: PackageRequest,
  events: ProcessEvents = {},
  signal?: AbortSignal,
): Promise<PackagedTarget[]> {
  const results: PackagedTarget[] = [];
  for (const target of request.targets) {
    await events.stderr?.(`\nPackaging ${target}...\n`);
    results.push(
      await packageApplication(
        { ...request, targets: [target] },
        events,
        signal,
      ),
    );
  }
  return results;
}

export class PackagingError extends Error {
  override readonly name = "PackagingError";
}

export async function packageApplication(
  unvalidatedRequest: PackageRequest,
  events: ProcessEvents = {},
  signal?: AbortSignal,
): Promise<PackageResult & ClientArchive> {
  const request = validatePackageRequest(unvalidatedRequest);
  if (request.targets.length !== 1) {
    throw new PackagingError("Package one target per build operation.");
  }
  const target = request.targets[0]!;
  const distribution = selectPythonDistribution(target, request.python);
  const artifactPath = expectedArtifactPath(request);
  const archivePath = clientArchivePath({ artifactPath, target });
  const checksumPath = `${archivePath}.sha256`;
  const destinations = [artifactPath, archivePath, checksumPath];
  await Promise.all(destinations.map(requireAbsent));
  signal?.throwIfAborted();
  await mkdir(request.outputDirectory, { recursive: true });

  const temporaryDirectory = await makeTempDir({
    dir: request.outputDirectory,
    prefix: ".bundlr-build-",
  });
  try {
    const paths = applicationPaths(request, temporaryDirectory);
    await mkdir(paths.packages, { recursive: true });

    await events.stderr?.(
      `Downloading Python ${distribution.pythonVersion} for ${target}...\n`,
    );
    await materializePythonRuntime(distribution, paths.runtime, signal);

    await events.stderr?.(
      `Installing target-compatible wheels for ${target}...\n`,
    );
    const uv = await resolveUvExecutable();
    if (request.source.kind === "pypi") {
      await requireSuccessfulInstall(
        uv,
        buildTargetInstallInvocation(request, distribution, paths.packages),
        events,
        signal,
      );
    } else {
      const root = await runInvocation(
        uv,
        buildGitRootInstallInvocation(request, paths.packages),
        { events, signal },
      );
      if (!root.success) {
        throw new PackagingError(
          `Git project wheel build failed with exit code ${root.code}.`,
        );
      }
    }

    const entryPoint = await findInstalledEntryPoint(
      paths.packages,
      request.command,
    );
    if (request.source.kind === "git") {
      await requirePortableGitWheel(entryPoint.metadataDirectory);
      const requirements = await readWheelRequirements(
        entryPoint.metadataDirectory,
      );
      if (requirements.length > 0) {
        await requireSuccessfulInstall(
          uv,
          buildTargetRequirementsInvocation(
            requirements,
            distribution,
            paths.packages,
          ),
          events,
          signal,
        );
      }
    }
    const effectiveRequest = {
      ...request,
      command: entryPoint.command,
      applicationKind:
        request.applicationKind === "auto"
          ? entryPoint.applicationKind
          : request.applicationKind,
    };
    await createApplicationLauncher(
      effectiveRequest,
      paths,
      distribution,
      entryPoint.value,
    );
    await writeManifest(
      effectiveRequest,
      paths.root,
      distribution.pythonVersion,
      entryPoint.command,
    );
    await writeSupplyChainFiles(paths.root, paths.packages);

    const stagedArtifact = join(temporaryDirectory, basename(artifactPath));
    signal?.throwIfAborted();
    const archive = await createClientArchive(
      { artifactPath: stagedArtifact, target },
      signal,
    );
    signal?.throwIfAborted();
    await Promise.all(destinations.map(requireAbsent));
    signal?.throwIfAborted();
    const published: string[] = [];
    try {
      await rename(stagedArtifact, artifactPath);
      published.push(artifactPath);
      await link(archive.archivePath, archivePath);
      published.push(archivePath);
      await link(archive.checksumPath, checksumPath);
      published.push(checksumPath);
      signal?.throwIfAborted();
    } catch (error) {
      for (const path of published.reverse()) {
        await rm(path, { recursive: path === artifactPath });
      }
      throw error;
    }
    return {
      artifactPath,
      target,
      archivePath,
      checksumPath,
      sha256: archive.sha256,
    };
  } catch (error) {
    if (error instanceof PythonRuntimeError) {
      throw new PackagingError(error.message, { cause: error });
    }
    throw error;
  } finally {
    await rm(temporaryDirectory, { recursive: true });
  }
}

async function requireSuccessfulInstall(
  uv: string,
  invocation: ReturnType<typeof buildTargetInstallInvocation>,
  events: ProcessEvents,
  signal?: AbortSignal,
): Promise<void> {
  const installation = await runInvocation(uv, invocation, { events, signal });
  if (!installation.success) {
    throw new PackagingError(
      `Target dependency installation failed with exit code ${installation.code}. ` +
        "Every dependency must provide a compatible wheel.",
    );
  }
}

function expectedArtifactPath(request: PackageRequest): string {
  const suffix =
    request.targets[0]?.startsWith("macos-") === true ? ".app" : "";
  return join(
    request.outputDirectory,
    `${request.applicationName}-${request.targets[0]}${suffix}`,
  );
}

async function requireAbsent(path: string): Promise<void> {
  try {
    await lstat(path);
  } catch (error) {
    if (isNotFound(error)) return;
    throw error;
  }
  throw new PackagingError(
    `Refusing to overwrite the existing artifact: ${path}`,
  );
}

async function writeManifest(
  request: PackageRequest,
  root: string,
  pythonVersion: string,
  command: string,
): Promise<void> {
  const source =
    request.source.kind === "git"
      ? request.source.url.href
      : request.source.requirement;
  await writeTextFile(
    join(root, "bundlr-manifest.json"),
    JSON.stringify(
      {
        formatVersion: 1,
        applicationName: request.applicationName,
        applicationKind: request.applicationKind,
        command,
        source,
        target: request.targets[0],
        pythonVersion,
        bundlrVersion: BUNDLR_VERSION,
      },
      null,
      2,
    ) + "\n",
    { createNew: true },
  );
}
