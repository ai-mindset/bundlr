import type { PackageSource } from "./source.ts";

export type TargetPlatform =
  | "linux-x86_64"
  | "macos-arm64"
  | "macos-x86_64"
  | "windows-x86_64";

export type ApplicationKind = "auto" | "console" | "windowed";

export interface PackageRequest {
  readonly source: PackageSource;
  readonly applicationName: string;
  readonly applicationKind: ApplicationKind;
  readonly command: string;
  readonly python: string;
  readonly targets: readonly TargetPlatform[];
  readonly outputDirectory: string;
}

export class InvalidPackageRequestError extends Error {
  override readonly name = "InvalidPackageRequestError";
}

export function validatePackageRequest(request: PackageRequest): PackageRequest {
  requireValue(request.applicationName, "Application name");
  if (
    request.applicationName === "." ||
    request.applicationName === ".." ||
    !/^[A-Za-z0-9][A-Za-z0-9 ._-]*$/.test(request.applicationName)
  ) {
    throw new InvalidPackageRequestError(
      "Application name may contain only letters, numbers, spaces, dots, underscores, and hyphens.",
    );
  }
  if (request.command.length > 0) requireValue(request.command, "Application command");
  requireValue(request.python, "Python version");
  requireValue(request.outputDirectory, "Output directory");

  if (request.targets.length === 0) {
    throw new InvalidPackageRequestError("Select at least one target platform.");
  }
  if (new Set(request.targets).size !== request.targets.length) {
    throw new InvalidPackageRequestError("Target platforms must be unique.");
  }
  return request;
}

function requireValue(value: string, label: string): void {
  if (value.trim().length === 0) {
    throw new InvalidPackageRequestError(`${label} is required.`);
  }
  if (value !== value.trim()) {
    throw new InvalidPackageRequestError(
      `${label} cannot begin or end with whitespace.`,
    );
  }
  if (value.includes("\0")) {
    throw new InvalidPackageRequestError(`${label} contains an invalid character.`);
  }
}
