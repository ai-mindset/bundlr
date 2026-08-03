import { assertEquals } from "jsr:@std/assert@1.0.19";
import { findApplicationEntries } from "./installed_entry_point.ts";

Deno.test("finds console and GUI entry points", () => {
  const metadata = `
[console_scripts]
example = example.cli:main

[gui_scripts]
example-gui = example.gui:start

[other]
example = ignored:main
`;

  assertEquals(findApplicationEntries(metadata, "example"), [{
    name: "example",
    value: "example.cli:main",
    applicationKind: "console",
  }]);
  assertEquals(findApplicationEntries(metadata, "example-gui"), [{
    name: "example-gui",
    value: "example.gui:start",
    applicationKind: "windowed",
  }]);
});

Deno.test("ignores malformed metadata and non-application groups", () => {
  assertEquals(findApplicationEntries("[plugins]\nexample = plugin:load\ninvalid", "example"), []);
});
