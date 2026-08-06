import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import {
  createPythonLauncher,
  InvalidEntryPointError,
  parsePythonEntryPoint,
} from "./entry_point.ts";

Deno.test("parses a Python console entry point", () => {
  assertEquals(parsePythonEntryPoint("example.cli:main"), {
    module: "example.cli",
    attributes: ["main"],
  });
});

Deno.test("parses nested attributes and ignores extras", () => {
  assertEquals(parsePythonEntryPoint("example.cli:Application.main [gui]"), {
    module: "example.cli",
    attributes: ["Application", "main"],
  });
});

Deno.test("rejects code injection in an entry point", () => {
  assertThrows(
    () => parsePythonEntryPoint("example; import os:main"),
    InvalidEntryPointError,
  );
});

Deno.test("creates a statically importable Python launcher", () => {
  assertEquals(
    createPythonLauncher({
      module: "example.cli",
      attributes: ["Application", "main"],
    }),
    "import example.cli as _bundlr_module\n\n" +
      'if __name__ == "__main__":\n' +
      "    raise SystemExit(_bundlr_module.Application.main())\n",
  );
});
