import { assertStringIncludes } from "jsr:@std/assert@1.0.19";
import { join } from "jsr:@std/path@1.1.2";
import type { PackageRequest, TargetPlatform } from "../domain/package_request.ts";
import { applicationPaths, createApplicationLauncher } from "./application_layout.ts";
import type { PythonDistribution } from "./python_distribution.ts";

Deno.test("Unix launchers disable Python bytecode writes", async () => {
  const buildDirectory = await Deno.makeTempDir({ prefix: "bundlr-launcher-test-" });
  try {
    for (const target of ["linux-x86_64", "macos-arm64"] as const) {
      const request: PackageRequest = {
        source: { kind: "pypi", requirement: "example==1.0.0" },
        applicationName: "Example",
        applicationKind: "console",
        command: "example",
        python: "3.12",
        targets: [target],
        outputDirectory: buildDirectory,
      };
      const paths = applicationPaths(request, buildDirectory);
      await Deno.mkdir(paths.root, { recursive: true });

      await createApplicationLauncher(
        request,
        paths,
        distribution(target),
        { module: "example", attributes: ["main"] },
      );

      const executable = target === "linux-x86_64"
        ? join(paths.root, request.applicationName)
        : join(paths.root, "..", "MacOS", request.applicationName);
      assertStringIncludes(
        await Deno.readTextFile(executable),
        ' -I -B "$ROOT/bundlr_launcher.py"',
      );
    }
  } finally {
    await Deno.remove(buildDirectory, { recursive: true });
  }
});

function distribution(target: TargetPlatform): PythonDistribution {
  return {
    target,
    pythonVersion: "3.12.13",
    archiveUrl: new URL("https://example.invalid/python.tar.gz"),
    sha256: "0".repeat(64),
    executablePath: "bin/python3",
    uvPlatform: target === "linux-x86_64" ? "x86_64-unknown-linux-gnu" : "aarch64-apple-darwin",
  };
}
