import { assertEquals } from "jsr:@std/assert@1.0.19";
import type { PackageRequest } from "../domain/package_request.ts";
import { selectPythonDistribution } from "./python_distribution.ts";
import { buildGitRootInstallInvocation, buildTargetInstallInvocation } from "./target_install.ts";

const request: PackageRequest = {
  source: { kind: "pypi", requirement: "example-app==1.2.3" },
  applicationName: "Example App",
  applicationKind: "windowed",
  command: "example-app",
  python: "3.12",
  targets: ["windows-x86_64"],
  outputDirectory: "dist",
};

Deno.test("installs target wheels without source-build fallback", () => {
  const invocation = buildTargetInstallInvocation(
    request,
    selectPythonDistribution("windows-x86_64", "3.12"),
    "/tmp/packages",
  );

  assertEquals(invocation.args, [
    "--no-config",
    "pip",
    "install",
    "--target",
    "/tmp/packages",
    "--python-version",
    "3.12.13",
    "--python-platform",
    "x86_64-pc-windows-msvc",
    "--only-binary",
    ":all:",
    "--no-installer-metadata",
    "example-app==1.2.3",
  ]);
});

Deno.test("passes an HTTPS Git source without a shell", () => {
  const invocation = buildGitRootInstallInvocation(
    { ...request, source: { kind: "git", url: new URL("https://example.com/app.git@abc") } },
    "packages",
  );

  assertEquals(invocation.args.at(-1), "git+https://example.com/app.git@abc");
  assertEquals(invocation.args.slice(-4, -1), [
    "packages",
    "--no-deps",
    "--no-installer-metadata",
  ]);
});
