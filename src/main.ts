import { PackageCliUsageError, parsePackageCliArgs } from "./cli/parse_package.ts";
import { InvalidEntryPointError } from "./core/entry_point.ts";
import { EntryPointNotFoundError } from "./core/installed_entry_point.ts";
import { PackagingError } from "./core/package_application.ts";
import { packageTargets } from "./core/package_targets.ts";
import { UnsupportedTargetError } from "./core/target.ts";
import { InvalidPackageRequestError } from "./domain/package_request.ts";
import { InvalidPackageSourceError } from "./domain/source.ts";
import { diagnoseUv } from "./platform/uv.ts";
import { BUNDLR_VERSION } from "./version.ts";

const HELP = `Bundlr ${BUNDLR_VERSION}

Package a Python application from PyPI or Git as a self-contained native application.

Usage:
  bundlr [OPTIONS] <PACKAGE>
  bundlr package [OPTIONS] <PACKAGE>

Options:
  -n, --name <NAME>       Application name (default: inferred from source)
  -c, --command <NAME>    Python application entry point (default: auto-detect)
  -k, --kind <KIND>       auto, windowed, or console (default: auto)
  -p, --python <VERSION>  Python version (default: 3.12)
  -t, --target <TARGET>   Build target; repeatable, or "all" (default: current platform)
  -o, --output <PATH>     Output directory (default: dist)
  -h, --help              Show this help
  -V, --version           Show the Bundlr version

Targets:
  linux-x86_64, macos-arm64, macos-x86_64, windows-x86_64

Examples:
  bundlr --kind console pycowsay==0.0.0.2
  bundlr --name Black --command black --kind console https://github.com/psf/black.git
`;

export async function main(args: readonly string[]): Promise<number> {
  try {
    const packageArgs = args[0] === "package" ? args.slice(1) : args;
    if (packageArgs[0] === "--help" || packageArgs[0] === "-h") {
      console.log(HELP);
      return 0;
    }
    if (packageArgs[0] === "--version" || packageArgs[0] === "-V") {
      console.log(BUNDLR_VERSION);
      return 0;
    }
    if (packageArgs[0] === "--diagnose") {
      console.log(`Bundlr ${BUNDLR_VERSION}`);
      console.log(await diagnoseUv());
      console.log("Runtime diagnostic passed.");
      return 0;
    }

    const request = parsePackageCliArgs(packageArgs);
    const encoder = new TextEncoder();
    const results = await packageTargets(request, {
      stdout: (text) => Deno.stdout.writeSync(encoder.encode(text)),
      stderr: (text) => Deno.stderr.writeSync(encoder.encode(text)),
    });
    for (const result of results) {
      console.log(`Created ${result.archivePath} for ${result.target} (${result.sha256}).`);
    }
    return 0;
  } catch (error) {
    if (isUsageError(error)) {
      console.error(`Error: ${error.message}\n\nRun bundlr --help for usage.`);
      return 2;
    }
    console.error(`Error: ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}

function isUsageError(error: unknown): error is Error {
  return error instanceof PackageCliUsageError ||
    error instanceof InvalidPackageSourceError ||
    error instanceof InvalidPackageRequestError ||
    error instanceof UnsupportedTargetError ||
    error instanceof EntryPointNotFoundError ||
    error instanceof InvalidEntryPointError ||
    error instanceof PackagingError;
}

if (import.meta.main) {
  Deno.exitCode = await main(Deno.args);
}
