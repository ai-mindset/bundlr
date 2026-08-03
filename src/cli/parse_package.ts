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
  let applicationKind: ApplicationKind = "auto";
  let python = "3.12";
  const targets: TargetPlatform[] = [];
  let outputDirectory = "dist";
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
        targets.push(...parseTargets(value));
        break;
      case "--output":
      case "-o":
        outputDirectory = value;
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
    : inferGitName(source.url);
  if (applicationName === undefined && inferredName === undefined) {
    throw new PackageCliUsageError("Could not infer the application name; use --name <name>.");
  }

  return {
    source,
    applicationName: applicationName ?? inferredName!,
    applicationKind,
    command: command ?? "",
    python,
    targets: targets.length === 0 ? [currentTarget()] : targets,
    outputDirectory,
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
  if (value === "auto" || value === "console" || value === "windowed") return value;
  throw new PackageCliUsageError("--kind must be auto, console, or windowed.");
}

function parseTargets(value: string): readonly TargetPlatform[] {
  if (value === "all") return TARGETS;
  if (TARGETS.includes(value as TargetPlatform)) return [value as TargetPlatform];
  throw new PackageCliUsageError(`Unsupported package target: ${value}`);
}

function inferDistributionName(requirement: string): string | undefined {
  return /^([A-Za-z0-9][A-Za-z0-9._-]*)/.exec(requirement)?.[1];
}

function inferGitName(url: URL): string | undefined {
  return url.pathname.split("/").filter(Boolean).at(-1)?.split("@", 1)[0]?.replace(/\.git$/, "");
}
