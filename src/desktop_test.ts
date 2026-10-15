import { test } from "bun:test";
import { assertStringIncludes } from "./test/assert.ts";
import { page } from "./desktop.ts";

test("desktop page includes an executable client and session token", () => {
  const html = page("linux-x86_64", "test-session-token", "test-page-id");
  assertStringIncludes(html, "test-session-token");
  assertStringIncludes(html, "test-page-id");
  assertStringIncludes(html, 'fetch("/package"');
  assertStringIncludes(html, 'fetch("/quit"');
  assertStringIncludes(html, 'fetch("/close"');
  const script = /<script>([\s\S]*?)<\/script>/.exec(html)?.[1];
  if (script === undefined) throw new Error("Desktop page has no client script.");
  new Function(script);
});
