import { basename, join } from "jsr:@std/path@1.1.2";
import type { PackageRequest } from "../domain/package_request.ts";
import type { PythonEntryPoint } from "./entry_point.ts";
import type { PythonDistribution } from "./python_distribution.ts";

export interface ApplicationPaths {
  readonly root: string;
  readonly runtime: string;
  readonly packages: string;
}

export function applicationPaths(
  request: PackageRequest,
  buildDirectory: string,
): ApplicationPaths {
  const target = request.targets[0]!;
  const artifactName = `${request.applicationName}-${target}`;
  const name = target.startsWith("macos-")
    ? `${artifactName}.app/Contents/Resources`
    : artifactName;
  const root = join(buildDirectory, name);
  return {
    root,
    runtime: join(root, "runtime"),
    packages: join(root, "packages"),
  };
}

export async function createApplicationLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  distribution: PythonDistribution,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const target = request.targets[0]!;
  if (target === "windows-x86_64") {
    await createWindowsLauncher(request, paths, distribution, entryPoint);
  } else if (target.startsWith("macos-")) {
    await createMacosLauncher(request, paths, distribution, entryPoint);
  } else {
    await createUnixLauncher(request, paths, distribution, entryPoint);
  }
}

function pythonInvocation(entryPoint: PythonEntryPoint, packagesExpression: string): string {
  const access = entryPoint.attributes.map((attribute) => `.${attribute}`).join("");
  return [
    "import sys",
    packagesExpression,
    `import ${entryPoint.module} as _bundlr_module`,
    `raise SystemExit(_bundlr_module${access}())`,
    "",
  ].join("\n");
}

async function createWindowsLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  distribution: PythonDistribution,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const sourceName = request.applicationKind === "windowed" ? "pythonw.exe" : "python.exe";
  const executableName = `${request.applicationName}.exe`;
  await Deno.copyFile(join(paths.runtime, sourceName), join(paths.root, executableName));
  await copyWindowsRuntimeLibraries(paths.runtime, paths.root);

  const pthName = `${basename(executableName, ".exe")}._pth`;
  await Deno.writeTextFile(
    join(paths.root, pthName),
    [
      `runtime/python${distribution.pythonVersion.replaceAll(".", "").slice(0, 3)}.zip`,
      "runtime/DLLs",
      "runtime/Lib",
      "packages",
      ".",
      "import site",
      "",
    ].join("\r\n"),
    { createNew: true },
  );
  await Deno.writeTextFile(
    join(paths.root, "sitecustomize.py"),
    pythonInvocation(
      entryPoint,
      "sys.path.insert(0, __file__.rsplit('\\\\', 1)[0] + '\\\\packages')",
    ),
    { createNew: true },
  );
}

async function copyWindowsRuntimeLibraries(runtime: string, destination: string): Promise<void> {
  for await (const entry of Deno.readDir(runtime)) {
    if (!entry.isFile || !entry.name.toLowerCase().endsWith(".dll")) continue;
    await Deno.copyFile(join(runtime, entry.name), join(destination, entry.name));
  }
}

async function createUnixLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  distribution: PythonDistribution,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const launcher = join(paths.root, "bundlr_launcher.py");
  await Deno.writeTextFile(
    launcher,
    pythonInvocation(entryPoint, "sys.path.insert(0, __file__.rsplit('/', 1)[0] + '/packages')"),
    { createNew: true },
  );
  const executable = join(paths.root, request.applicationName);
  await Deno.writeTextFile(
    executable,
    `#!/bin/sh\nROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n` +
      `exec "$ROOT/runtime/${distribution.executablePath}" -I -B "$ROOT/bundlr_launcher.py" "$@"\n`,
    { createNew: true, mode: 0o755 },
  );
  await Deno.chmod(executable, 0o755);
}

async function createMacosLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  distribution: PythonDistribution,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const contents = join(paths.root, "..");
  const macos = join(contents, "MacOS");
  await Deno.mkdir(macos, { recursive: true });
  const launcher = join(paths.root, "bundlr_launcher.py");
  await Deno.writeTextFile(
    launcher,
    pythonInvocation(entryPoint, "sys.path.insert(0, __file__.rsplit('/', 1)[0] + '/packages')"),
    { createNew: true },
  );
  const executable = join(macos, request.applicationName);
  await Deno.writeTextFile(
    executable,
    `#!/bin/sh\nROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../Resources" && pwd)\n` +
      `exec "$ROOT/runtime/${distribution.executablePath}" -I -B "$ROOT/bundlr_launcher.py" "$@"\n`,
    { createNew: true, mode: 0o755 },
  );
  await Deno.chmod(executable, 0o755);
  await Deno.writeTextFile(
    join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
      `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ` +
      `"https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n` +
      `<plist version="1.0"><dict>` +
      `<key>CFBundleExecutable</key><string>${escapeXml(request.applicationName)}</string>` +
      `<key>CFBundleIdentifier</key><string>dev.bundlr.${
        bundleIdentifier(request.applicationName)
      }</string>` +
      `<key>CFBundleName</key><string>${escapeXml(request.applicationName)}</string>` +
      `<key>CFBundlePackageType</key><string>APPL</string>` +
      `</dict></plist>\n`,
    { createNew: true },
  );
}

function bundleIdentifier(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9.-]+/g, "-");
}

function escapeXml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
