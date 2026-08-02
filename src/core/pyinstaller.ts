import type { PackageRequest } from "../domain/package_request.ts";
import type { Invocation } from "./invocation.ts";

export const PYINSTALLER_VERSION = "6.21.0";

export interface PyInstallerPaths {
  readonly launcher: string;
  readonly workDirectory: string;
}

export function buildPyInstallerInvocation(
  request: PackageRequest,
  paths: PyInstallerPaths,
): Invocation {
  const source = request.source.kind === "git"
    ? `git+${request.source.url.href}`
    : request.source.requirement;

  const pyinstallerArgs = [
    "--noconfirm",
    "--clean",
    "--onedir",
    "--noupx",
    "--name",
    request.applicationName,
    "--distpath",
    request.outputDirectory,
    "--workpath",
    paths.workDirectory,
    "--specpath",
    paths.workDirectory,
  ];
  if (request.applicationKind === "windowed") {
    pyinstallerArgs.push("--windowed");
  }
  for (const packageName of request.collectPackages ?? []) {
    pyinstallerArgs.push("--collect-all", packageName);
  }
  pyinstallerArgs.push(paths.launcher);

  return {
    args: [
      "--no-config",
      "run",
      "--no-project",
      "--python",
      request.python,
      "--with",
      source,
      "--with",
      `pyinstaller==${PYINSTALLER_VERSION}`,
      "python",
      "-m",
      "PyInstaller",
      ...pyinstallerArgs,
    ],
    env: {
      UV_NO_SYSTEM_CONFIG: "1",
      UV_PYTHON_PREFERENCE: "only-managed",
    },
  };
}
