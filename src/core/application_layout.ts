import { readFile, writeFile, mkdir, chmod } from "node:fs/promises";
import { writeTextFile } from "../platform/fs.ts";
import JSZip from "jszip";
import { join } from "node:path";
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
    await createWindowsLauncher(request, paths, entryPoint);
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
    "import site",
    packagesExpression,
    `import ${entryPoint.module} as _bundlr_module`,
    `raise SystemExit(_bundlr_module${access}())`,
    "",
  ].join("\n");
}

async function createWindowsLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const windowed = request.applicationKind === "windowed";
  const sourceName = windowed ? "pythonw.exe" : "python.exe";
  const stubName = windowed ? "w64.exe" : "t64.exe";
  const executableName = `${request.applicationName}.exe`;
  const stub = await readFile(
    join(paths.runtime, "Lib", "site-packages", "pip", "_vendor", "distlib", stubName),
  );
  const shebang = new TextEncoder().encode(`#!<launcher_dir>\\runtime\\${sourceName} -I -B\n`);
  const main = pythonInvocation(
    entryPoint,
    "import os\n" +
      "site.addsitedir(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), 'packages'))",
  );
  const zip = new JSZip();
  zip.file("__main__.py", main, {
    createFolders: false,
    date: new Date("2000-01-01T00:00:00.000Z"),
  });
  const archive = await zip.generateAsync({ type: "uint8array", compression: "STORE" });
  const launcher = new Uint8Array(stub.length + shebang.length + archive.length);
  launcher.set(stub);
  launcher.set(shebang, stub.length);
  launcher.set(archive, stub.length + shebang.length);
  await writeFile(join(paths.root, executableName), launcher, { flag: "wx" });
}

async function createUnixLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  distribution: PythonDistribution,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const launcher = join(paths.root, "bundlr_launcher.py");
  await writeTextFile(
    launcher,
    pythonInvocation(entryPoint, "site.addsitedir(__file__.rsplit('/', 1)[0] + '/packages')"),
    { createNew: true },
  );
  const executable = join(paths.root, request.applicationName);
  await writeTextFile(
    executable,
    `#!/bin/sh\nROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n` +
      `exec "$ROOT/runtime/${distribution.executablePath}" -I -B "$ROOT/bundlr_launcher.py" "$@"\n`,
    { createNew: true, mode: 0o755 },
  );
  await chmod(executable, 0o755);
}

async function createMacosLauncher(
  request: PackageRequest,
  paths: ApplicationPaths,
  distribution: PythonDistribution,
  entryPoint: PythonEntryPoint,
): Promise<void> {
  const contents = join(paths.root, "..");
  const macos = join(contents, "MacOS");
  await mkdir(macos, { recursive: true });
  const launcher = join(paths.root, "bundlr_launcher.py");
  await writeTextFile(
    launcher,
    pythonInvocation(entryPoint, "site.addsitedir(__file__.rsplit('/', 1)[0] + '/packages')"),
    { createNew: true },
  );
  const executable = join(macos, request.applicationName);
  await writeTextFile(
    executable,
    `#!/bin/sh\nROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../Resources" && pwd)\n` +
      `exec "$ROOT/runtime/${distribution.executablePath}" -I -B "$ROOT/bundlr_launcher.py" "$@"\n`,
    { createNew: true, mode: 0o755 },
  );
  await chmod(executable, 0o755);
  await writeTextFile(
    join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
      `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ` +
      `"https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n` +
      `<plist version="1.0"><dict>` +
      `<key>CFBundleExecutable</key><string>${escapeXml(request.applicationName)}</string>` +
      `<key>CFBundleIdentifier</key><string>dev.bundlr.${bundleIdentifier(
        request.applicationName,
      )}</string>` +
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
