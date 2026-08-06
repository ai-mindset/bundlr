import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import { PackageCliUsageError, parsePackageCliArgs } from "./parse_package.ts";

Deno.test("infers a PyPI application name and command", () => {
  const request = parsePackageCliArgs([
    "--target",
    "linux-x86_64",
    "example_app==1.2.3",
  ]);
  assertEquals(request.applicationName, "example_app");
  assertEquals(request.command, "");
  assertEquals(request.applicationKind, "auto");
  assertEquals(request.python, "3.12");
  assertEquals(request.targets, ["linux-x86_64"]);
  assertEquals(request.outputDirectory, "dist");
});

Deno.test("parses explicit packaging options", () => {
  const request = parsePackageCliArgs([
    "--name",
    "Example App",
    "--command",
    "example",
    "--kind",
    "console",
    "--python",
    "3.11",
    "--target",
    "windows-x86_64",
    "--output",
    "client builds",
    "https://github.com/example/app.git",
  ]);
  assertEquals(request.applicationName, "Example App");
  assertEquals(request.command, "example");
  assertEquals(request.applicationKind, "console");
  assertEquals(request.python, "3.11");
  assertEquals(request.targets, ["windows-x86_64"]);
  assertEquals(request.outputDirectory, "client builds");
  assertEquals(request.source.kind, "git");
});

Deno.test("infers a Git application name and auto-detects its command", () => {
  const request = parsePackageCliArgs(["https://github.com/example/example-app.git@abc123"]);
  assertEquals(request.applicationName, "example-app");
  assertEquals(request.command, "");
});

Deno.test("rejects invalid kinds and targets", () => {
  assertThrows(
    () => parsePackageCliArgs(["--kind", "service", "example-app"]),
    PackageCliUsageError,
    "auto, console, or windowed",
  );
  assertThrows(
    () => parsePackageCliArgs(["--target", "web", "example-app"]),
    PackageCliUsageError,
    "Unsupported package target",
  );
});

Deno.test("expands the all-target shortcut", () => {
  const request = parsePackageCliArgs(["--target", "all", "example-app==1.0.0"]);
  assertEquals(request.targets, [
    "linux-x86_64",
    "macos-arm64",
    "macos-x86_64",
    "windows-x86_64",
  ]);
});

Deno.test("rejects unknown options and trailing arguments", () => {
  assertThrows(
    () => parsePackageCliArgs(["--unknown", "value", "example-app"]),
    PackageCliUsageError,
    "Unknown package option",
  );
  assertThrows(
    () => parsePackageCliArgs(["example-app", "unexpected"]),
    PackageCliUsageError,
    "Unexpected arguments",
  );
});
