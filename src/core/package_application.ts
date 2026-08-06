import { basename, join } from "jsr:@std/path@1.1.2";
import { type PackageRequest, validatePackageRequest } from "../domain/package_request.ts";
import { resolveUvExecutable } from "../platform/uv.ts";
import { applicationPaths, createApplicationLauncher } from "./application_layout.ts";
import { findInstalledEntryPoint } from "./installed_entry_point.ts";
import { type ProcessEvents, runInvocation } from "./process.ts";
import { selectPythonDistribution } from "./python_distribution.ts";
import { materializePythonRuntime, PythonRuntimeError } from "./python_runtime.ts";
import { requirePortableGitWheel } from "./portable_wheel.ts";
import { writeSupplyChainFiles } from "./supply_chain.ts";
import {
  buildGitRootInstallInvocation,
  buildTargetInstallInvocation,
  buildTargetRequirementsInvocation,
} from "./target_install.ts";
import { readWheelRequirements } from "./wheel_metadata.ts";
import { BUNDLR_VERSION } from "../version.ts";

export interface PackageResult {
  readonly artifactPath: string;
  readonly target: string;
}

export class PackagingError extends Error {
  override readonly name = "PackagingError";
}

export async function packageApplication(
  unvalidatedRequest: PackageRequest,
  events: ProcessEvents = {},
  signal?: AbortSignal,
): Promise<PackageResult> {
  const request = validatePackageRequest(unvalidatedRequest);
  if (request.targets.length !== 1) {
    throw new PackagingError("Package one target per build operation.");
  }
  const target = request.targets[0]!;
  const distribution = selectPythonDistribution(target, request.python);
  const artifactPath = expectedArtifactPath(request);
  await requireAbsent(artifactPath);
  await Deno.mkdir(request.outputDirectory, { recursive: true });

  const temporaryDirectory = await Deno.makeTempDir({
    dir: request.outputDirectory,
    prefix: ".bundlr-build-",
  });
  try {
    const paths = applicationPaths(request, temporaryDirectory);
    await Deno.mkdir(paths.packages, { recursive: true });

    events.stderr?.(`Downloading Python ${distribution.pythonVersion} for ${target}...\n`);
    await materializePythonRuntime(distribution, paths.runtime, signal);

    events.stderr?.(`Installing target-compatible wheels for ${target}...\n`);
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
        throw new PackagingError(`Git project wheel build failed with exit code ${root.code}.`);
      }
    }

    const entryPoint = await findInstalledEntryPoint(paths.packages, request.command);
    if (request.source.kind === "git") {
      await requirePortableGitWheel(entryPoint.metadataDirectory);
      const requirements = await readWheelRequirements(entryPoint.metadataDirectory);
      if (requirements.length > 0) {
        await requireSuccessfulInstall(
          uv,
          buildTargetRequirementsInvocation(requirements, distribution, paths.packages),
          events,
          signal,
        );
      }
    }
    const effectiveRequest = request.applicationKind === "auto"
      ? { ...request, applicationKind: entryPoint.applicationKind }
      : request;
    await createApplicationLauncher(effectiveRequest, paths, distribution, entryPoint.value);
    await writeManifest(
      effectiveRequest,
      paths.root,
      distribution.pythonVersion,
      entryPoint.command,
    );
    await writeSupplyChainFiles(paths.root, paths.packages);

    const stagedArtifact = join(temporaryDirectory, basename(artifactPath));
    await Deno.rename(stagedArtifact, artifactPath);
    return { artifactPath, target };
  } catch (error) {
    if (error instanceof PythonRuntimeError) {
      throw new PackagingError(error.message, { cause: error });
    }
    throw error;
  } finally {
    await Deno.remove(temporaryDirectory, { recursive: true });
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
  const suffix = request.targets[0]?.startsWith("macos-") === true ? ".app" : "";
  return join(
    request.outputDirectory,
    `${request.applicationName}-${request.targets[0]}${suffix}`,
  );
}

async function requireAbsent(path: string): Promise<void> {
  try {
    await Deno.lstat(path);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return;
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
  const source = request.source.kind === "git"
    ? request.source.url.href
    : request.source.requirement;
  await Deno.writeTextFile(
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
