import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import type { PackageRequest } from "../domain/package_request.ts";
import {
  buildEntryPointInspection,
  decodeInspectedEntryPoint,
  EntryPointNotFoundError,
} from "./inspect_entry_point.ts";

const request: PackageRequest = {
  source: { kind: "pypi", requirement: "example-app==1.0.0" },
  applicationName: "Example App",
  applicationKind: "console",
  command: "example-app",
  python: "3.12",
  targets: ["linux-x86_64"],
  outputDirectory: "dist",
};

Deno.test("builds an isolated uv inspection command", () => {
  const invocation = buildEntryPointInspection(request);
  assertEquals(invocation.args.slice(0, 8), [
    "--no-config",
    "run",
    "--no-project",
    "--python",
    "3.12",
    "--with",
    "example-app==1.0.0",
    "python",
  ]);
  const script = invocation.args.at(-2);
  assertEquals(script?.includes('"console_scripts", "gui_scripts"'), true);
  assertEquals(invocation.args.at(-1), "example-app");
});

Deno.test("decodes one matching console entry point", () => {
  assertEquals(
    decodeInspectedEntryPoint(
      '[{"name":"example-app","value":"example.cli:main"}]',
      "example-app",
    ),
    { module: "example.cli", attributes: ["main"] },
  );
});

Deno.test("reports a missing console entry point", () => {
  assertThrows(
    () => decodeInspectedEntryPoint("[]", "missing"),
    EntryPointNotFoundError,
    'does not provide a "missing" application entry point',
  );
});

Deno.test("rejects ambiguous console entry points", () => {
  assertThrows(
    () =>
      decodeInspectedEntryPoint(
        '[{"value":"one:main"},{"value":"two:main"}]',
        "example-app",
      ),
    EntryPointNotFoundError,
    "More than one",
  );
});
