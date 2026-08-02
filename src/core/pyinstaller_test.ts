import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.14";
import type { PackageRequest } from "../domain/package_request.ts";
import { buildPyInstallerInvocation, PYINSTALLER_VERSION } from "./pyinstaller.ts";

const request: PackageRequest = {
  source: { kind: "pypi", requirement: "example-app==1.0.0" },
  applicationName: "Example App",
  applicationKind: "windowed",
  command: "example-app",
  python: "3.12",
  targets: ["linux-x86_64"],
  outputDirectory: "client builds",
  collectPackages: ["textual"],
};

Deno.test("builds a pinned one-directory PyInstaller invocation", () => {
  const invocation = buildPyInstallerInvocation(request, {
    launcher: "/tmp/build directory/launcher.py",
    workDirectory: "/tmp/build directory/work",
  });

  assertEquals(invocation.args.slice(0, 13), [
    "--no-config",
    "run",
    "--no-project",
    "--python",
    "3.12",
    "--with",
    "example-app==1.0.0",
    "--with",
    `pyinstaller==${PYINSTALLER_VERSION}`,
    "python",
    "-m",
    "PyInstaller",
    "--noconfirm",
  ]);
  assert(invocation.args.includes("--onedir"));
  assert(invocation.args.includes("--noupx"));
  assert(invocation.args.includes("--windowed"));
  const collectIndex = invocation.args.indexOf("--collect-all");
  assertEquals(invocation.args[collectIndex + 1], "textual");
  assertEquals(invocation.args.at(-1), "/tmp/build directory/launcher.py");
});

Deno.test("omits windowed mode for console applications", () => {
  const invocation = buildPyInstallerInvocation(
    { ...request, applicationKind: "console" },
    { launcher: "launcher.py", workDirectory: "work" },
  );
  assertFalse(invocation.args.includes("--windowed"));
});

Deno.test("converts an HTTPS Git source for uv", () => {
  const invocation = buildPyInstallerInvocation(
    {
      ...request,
      source: { kind: "git", url: new URL("https://github.com/example/app.git") },
    },
    { launcher: "launcher.py", workDirectory: "work" },
  );
  assert(invocation.args.includes("git+https://github.com/example/app.git"));
});
