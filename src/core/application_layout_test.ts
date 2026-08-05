import { TextWriter, Uint8ArrayReader, ZipReader } from "jsr:@zip-js/zip-js@2.8.34";
import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import { join } from "jsr:@std/path@1.1.2";
import type { PackageRequest, TargetPlatform } from "../domain/package_request.ts";
import { applicationPaths, createApplicationLauncher } from "./application_layout.ts";
import type { PythonDistribution } from "./python_distribution.ts";

Deno.test("Unix launchers isolate Python and process bundled site packages", async () => {
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
      const pythonLauncher = await Deno.readTextFile(join(paths.root, "bundlr_launcher.py"));
      assertStringIncludes(pythonLauncher, "import site");
      assertStringIncludes(
        pythonLauncher,
        "site.addsitedir(__file__.rsplit('/', 1)[0] + '/packages')",
      );
    }
  } finally {
    await Deno.remove(buildDirectory, { recursive: true });
  }
});

Deno.test("Windows launchers embed an isolated relocatable Python entry point", async () => {
  const buildDirectory = await Deno.makeTempDir({ prefix: "bundlr-launcher-test-" });
  try {
    for (
      const launcher of [
        { applicationKind: "windowed", stubName: "w64.exe", pythonName: "pythonw.exe" },
        { applicationKind: "console", stubName: "t64.exe", pythonName: "python.exe" },
      ] as const
    ) {
      const applicationName = `Example-${launcher.applicationKind}`;
      const request: PackageRequest = {
        source: { kind: "pypi", requirement: "example==1.0.0" },
        applicationName,
        applicationKind: launcher.applicationKind,
        command: "example",
        python: "3.12",
        targets: ["windows-x86_64"],
        outputDirectory: buildDirectory,
      };
      const paths = applicationPaths(request, buildDirectory);
      const stubDirectory = join(
        paths.runtime,
        "Lib",
        "site-packages",
        "pip",
        "_vendor",
        "distlib",
      );
      await Deno.mkdir(stubDirectory, { recursive: true });
      const stub = new Uint8Array([0x4d, 0x5a, 0x00, 0x01]);
      await Deno.writeFile(join(stubDirectory, launcher.stubName), stub);

      await createApplicationLauncher(
        request,
        paths,
        distribution("windows-x86_64"),
        { module: "example", attributes: ["main"] },
      );

      const executable = await Deno.readFile(join(paths.root, `${applicationName}.exe`));
      assertEquals(executable.slice(0, stub.length), stub);
      const shebang = new TextEncoder().encode(
        `#!<launcher_dir>\\runtime\\${launcher.pythonName} -I -B\n`,
      );
      assertEquals(executable.slice(stub.length, stub.length + shebang.length), shebang);

      const archive = executable.slice(stub.length + shebang.length);
      assertEquals(Array.from(archive.slice(-22, -18)), [0x50, 0x4b, 0x05, 0x06]);
      const zipReader = new ZipReader(new Uint8ArrayReader(archive));
      try {
        const entries = await zipReader.getEntries();
        assertEquals(entries.length, 1);
        const entry = entries[0]!;
        assertEquals(entry.filename, "__main__.py");
        if (!("getData" in entry)) throw new Error("Expected __main__.py to be a file.");
        const main = await entry.getData(new TextWriter());
        assertStringIncludes(main, "import site");
        assertStringIncludes(
          main,
          "site.addsitedir(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), 'packages'))",
        );
        assertStringIncludes(main, "import example as _bundlr_module");
        assertStringIncludes(main, "raise SystemExit(_bundlr_module.main())");
      } finally {
        await zipReader.close();
      }

      const rootEntries: string[] = [];
      for await (const entry of Deno.readDir(paths.root)) rootEntries.push(entry.name);
      assertEquals(rootEntries.sort(), [`${applicationName}.exe`, "runtime"].sort());
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
