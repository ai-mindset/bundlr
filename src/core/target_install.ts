import type { PackageRequest } from "../domain/package_request.ts";
import type { PythonDistribution } from "./python_distribution.ts";
import type { Invocation } from "./invocation.ts";

export function buildTargetInstallInvocation(
  request: PackageRequest,
  distribution: PythonDistribution,
  destination: string,
): Invocation {
  if (request.source.kind !== "pypi") {
    throw new Error("Use the staged Git install flow for Git sources.");
  }

  return buildBinaryInstallInvocation(
    request.source.requirement,
    distribution,
    destination,
  );
}

export function buildGitRootInstallInvocation(
  request: PackageRequest,
  destination: string,
): Invocation {
  if (request.source.kind !== "git") throw new Error("A Git source is required.");
  return {
    args: [
      "--no-config",
      "pip",
      "install",
      "--target",
      destination,
      "--no-deps",
      "--no-installer-metadata",
      `git+${request.source.url.href}`,
    ],
    env: installationEnvironment(),
  };
}

export function buildTargetRequirementsInvocation(
  requirements: readonly string[],
  distribution: PythonDistribution,
  destination: string,
): Invocation {
  if (requirements.length === 0) throw new Error("At least one requirement is required.");
  return buildBinaryInstallInvocation(requirements, distribution, destination);
}

function buildBinaryInstallInvocation(
  requirements: string | readonly string[],
  distribution: PythonDistribution,
  destination: string,
): Invocation {
  return {
    args: [
      "--no-config",
      "pip",
      "install",
      "--target",
      destination,
      "--python-version",
      distribution.pythonVersion,
      "--python-platform",
      distribution.uvPlatform,
      "--only-binary",
      ":all:",
      "--no-installer-metadata",
      ...(typeof requirements === "string" ? [requirements] : requirements),
    ],
    env: installationEnvironment(),
  };
}

function installationEnvironment(): Readonly<Record<string, string>> {
  return {
    UV_NO_SYSTEM_CONFIG: "1",
    UV_PYTHON_PREFERENCE: "only-managed",
    UV_LINK_MODE: "copy",
  };
}
