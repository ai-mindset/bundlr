import {
  type ApplicationKind,
  type PackageRequest,
  type TargetPlatform,
} from "../domain/package_request.ts";
import { parsePackageSource } from "../domain/source.ts";
import { currentTarget } from "../core/target.ts";

const TARGETS: readonly TargetPlatform[] = [
  "linux-x86_64",
  "macos-arm64",
  "macos-x86_64",
  "windows-x86_64",
];

export class PackageCliUsageError extends Error {
  override readonly name = "PackageCliUsageError";
}

export function parsePackageCliArgs(args: readonly string[]): PackageRequest {
  let applicationName: string | undefined;
  let command: string | undefined;
  let applicationKind: ApplicationKind = "windowed";
  let python = "3.12";
  let target = currentTarget();
  let outputDirectory = "dist";
  const collectPackages: string[] = [];
  let index = 0;

  while (index < args.length) {
    const option = args[index];
    if (option === undefined) break;
    if (!option.startsWith("-")) break;

    const value = requiredOptionValue(args, index, option);
    switch (option) {
      case "--name":
      case "-n":
        applicationName = value;
        break;
      case "--command":
      case "-c":
        command = value;
        break;
      case "--kind":
      case "-k":
        applicationKind = parseApplicationKind(value);
        break;
      case "--python":
      case "-p":
        python = value;
        break;
      case "--target":
      case "-t":
        target = parseTarget(value);
        break;
      case "--output":
      case "-o":
        outputDirectory = value;
        break;
      case "--collect":
        collectPackages.push(value);
        break;
      default:
        throw new PackageCliUsageError(`Unknown package option: ${option}`);
    }
    index += 2;
  }

  const sourceInput = args[index];
  if (sourceInput === undefined) {
    throw new PackageCliUsageError("A PyPI requirement or HTTPS Git URL is required.");
  }
  if (index + 1 !== args.length) {
    throw new PackageCliUsageError("Unexpected arguments after the package source.");
  }

  const source = parsePackageSource(sourceInput);
  const inferredName = source.kind === "pypi"
    ? inferDistributionName(source.requirement)
    : undefined;
  if (applicationName === undefined && inferredName === undefined) {
    throw new PackageCliUsageError("Git sources require --name <application-name>.");
  }
  if (command === undefined && inferredName === undefined) {
    throw new PackageCliUsageError("Git sources require --command <entry-point>.");
  }

  return {
    source,
    applicationName: applicationName ?? inferredName!,
    applicationKind,
    command: command ?? normalizeCommand(inferredName!),
    python,
    targets: [target],
    outputDirectory,
    ...(collectPackages.length === 0 ? {} : { collectPackages }),
  };
}

function requiredOptionValue(
  args: readonly string[],
  index: number,
  option: string,
): string {
  const value = args[index + 1];
  if (value === undefined || value.length === 0 || value.startsWith("-")) {
    throw new PackageCliUsageError(`${option} requires a value.`);
  }
  return value;
}

function parseApplicationKind(value: string): ApplicationKind {
  if (value === "console" || value === "windowed") return value;
  throw new PackageCliUsageError("--kind must be console or windowed.");
}

function parseTarget(value: string): TargetPlatform {
  if (TARGETS.includes(value as TargetPlatform)) return value as TargetPlatform;
  throw new PackageCliUsageError(`Unsupported package target: ${value}`);
}

function inferDistributionName(requirement: string): string | undefined {
  return /^([A-Za-z0-9][A-Za-z0-9._-]*)/.exec(requirement)?.[1];
}

function normalizeCommand(name: string): string {
  return name.toLowerCase().replace(/[_.]+/g, "-");
}
