import { test } from "bun:test";
import { assertEquals, assertThrows } from "../test/assert.ts";
import {
  createPythonLauncher,
  findApplicationEntries,
  InvalidEntryPointError,
  parsePythonEntryPoint,
} from "./entry_point.ts";

test("parses a Python console entry point", () => {
  assertEquals(parsePythonEntryPoint("example.cli:main"), {
    module: "example.cli",
    attributes: ["main"],
  });
});

test("parses nested attributes and ignores extras", () => {
  assertEquals(parsePythonEntryPoint("example.cli:Application.main [gui]"), {
    module: "example.cli",
    attributes: ["Application", "main"],
  });
});

test("rejects code injection in an entry point", () => {
  assertThrows(
    () => parsePythonEntryPoint("example; import os:main"),
    InvalidEntryPointError,
  );
});

test("creates a statically importable Python launcher", () => {
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

test("finds console and GUI entry points", () => {
  const metadata = `
[console_scripts]
example = example.cli:main

[gui_scripts]
example-gui = example.gui:start

[other]
example = ignored:main
`;

  assertEquals(findApplicationEntries(metadata, "example"), [
    {
      name: "example",
      value: "example.cli:main",
      applicationKind: "console",
    },
  ]);
  assertEquals(findApplicationEntries(metadata, "example-gui"), [
    {
      name: "example-gui",
      value: "example.gui:start",
      applicationKind: "windowed",
    },
  ]);
});

test("ignores malformed metadata and non-application groups", () => {
  assertEquals(
    findApplicationEntries(
      "[plugins]\nexample = plugin:load\ninvalid",
      "example",
    ),
    [],
  );
});
