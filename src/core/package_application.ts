import { join } from "jsr:@std/path@1.1.2";
import { type PackageRequest, validatePackageRequest } from "../domain/package_request.ts";
import { resolveUvExecutable } from "../platform/uv.ts";
import { createPythonLauncher } from "./entry_point.ts";
import { buildEntryPointInspection, decodeInspectedEntryPoint } from "./inspect_entry_point.ts";
import { type ProcessEvents, runInvocation } from "./process.ts";
import { buildPyInstallerInvocation } from "./pyinstaller.ts";
import { currentTarget, requireNativeTarget } from "./target.ts";

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
  const target = requireNativeTarget(request.targets);
  const artifactPath = expectedArtifactPath(request);
  await requireAbsent(artifactPath);

  const temporaryDirectory = await Deno.makeTempDir({ prefix: "bundlr-build-" });
  try {
    const workDirectory = join(temporaryDirectory, "work");
    const launcherPath = join(temporaryDirectory, "launcher.py");
    await Deno.mkdir(workDirectory);

    const uv = await resolveUvExecutable();
    const inspection = await runInvocation(
      uv,
      buildEntryPointInspection(request),
      { captureStdout: true, events: { stderr: events.stderr }, signal },
    );
    if (!inspection.success) {
      throw new PackagingError(
        `Package inspection failed with exit code ${inspection.code}.`,
      );
    }

    const entryPoint = decodeInspectedEntryPoint(
      inspection.stdout ?? "",
      request.command,
    );
    await Deno.writeTextFile(
      launcherPath,
      createPythonLauncher(entryPoint),
      { createNew: true },
    );
    await Deno.mkdir(request.outputDirectory, { recursive: true });

    const build = await runInvocation(
      uv,
      buildPyInstallerInvocation(request, {
        launcher: launcherPath,
        workDirectory,
      }),
      { events, signal },
    );
    if (!build.success) {
      throw new PackagingError(
        `PyInstaller failed with exit code ${build.code}.`,
      );
    }

    await requirePresent(artifactPath);
    return { artifactPath, target };
  } finally {
    await Deno.remove(temporaryDirectory, { recursive: true });
  }
}

function expectedArtifactPath(request: PackageRequest): string {
  const suffix = currentTarget().startsWith("macos-") &&
      request.applicationKind === "windowed"
    ? ".app"
    : "";
  return join(request.outputDirectory, `${request.applicationName}${suffix}`);
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

async function requirePresent(path: string): Promise<void> {
  try {
    await Deno.lstat(path);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      throw new PackagingError(
        `PyInstaller completed without creating the expected artifact: ${path}`,
      );
    }
    throw error;
  }
}
