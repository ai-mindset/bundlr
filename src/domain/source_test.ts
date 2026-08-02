import { InvalidPackageSourceError, parsePackageSource } from "./source.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("parses a PyPI requirement", () => {
  const source = parsePackageSource("  httpie>=3  ");
  assert(source.kind === "pypi", "expected a PyPI source");
  assert(source.requirement === "httpie>=3", "requirement should be trimmed");
});

Deno.test("parses an HTTPS Git source", () => {
  const source = parsePackageSource("git+https://github.com/httpie/cli.git");
  assert(source.kind === "git", "expected a Git source");
  assert(source.url.hostname === "github.com", "expected the parsed hostname");
});

Deno.test("rejects an empty source", () => {
  let error: unknown;
  try {
    parsePackageSource("  ");
  } catch (caught) {
    error = caught;
  }
  assert(error instanceof InvalidPackageSourceError, "expected a source validation error");
});

Deno.test("rejects an insecure Git URL", () => {
  let error: unknown;
  try {
    parsePackageSource("http://example.com/application.git");
  } catch (caught) {
    error = caught;
  }
  assert(error instanceof InvalidPackageSourceError, "expected HTTPS to be required");
});
