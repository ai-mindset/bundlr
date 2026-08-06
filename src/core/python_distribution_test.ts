import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.19";
import { selectPythonDistribution } from "./python_distribution.ts";

Deno.test("selects the pinned Windows distribution", () => {
  const distribution = selectPythonDistribution("windows-x86_64", "3.12");

  assertEquals(distribution.pythonVersion, "3.12.13");
  assertEquals(distribution.uvPlatform, "x86_64-pc-windows-msvc");
  assertEquals(distribution.executablePath, "python.exe");
  assertEquals(
    distribution.archiveUrl.pathname,
    "/astral-sh/python-build-standalone/releases/download/20260718/" +
      "cpython-3.12.13+20260718-x86_64-pc-windows-msvc-install_only_stripped.tar.gz",
  );
});

Deno.test("selects target-specific Unix distributions", () => {
  assertEquals(
    selectPythonDistribution("linux-x86_64", "3.12.13").uvPlatform,
    "x86_64-unknown-linux-gnu",
  );
  assertEquals(
    selectPythonDistribution("macos-arm64", "3.12").uvPlatform,
    "aarch64-apple-darwin",
  );
  assertEquals(
    selectPythonDistribution("macos-x86_64", "3.12").uvPlatform,
    "x86_64-apple-darwin",
  );
});

Deno.test("rejects an unsupported Python version", () => {
  assertThrows(
    () => selectPythonDistribution("linux-x86_64", "3.13"),
    Error,
    "currently supports Python 3.12",
  );
});
