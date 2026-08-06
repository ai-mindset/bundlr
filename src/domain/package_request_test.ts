import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import {
  InvalidPackageRequestError,
  type PackageRequest,
  validatePackageRequest,
} from "./package_request.ts";

const validRequest: PackageRequest = {
  source: { kind: "pypi", requirement: "example-app==1.0.0" },
  applicationName: "Example App",
  applicationKind: "windowed",
  command: "example-app",
  python: "3.12",
  targets: ["linux-x86_64"],
  outputDirectory: "dist",
};

Deno.test("accepts a complete package request", () => {
  assertEquals(validatePackageRequest(validRequest), validRequest);
});

Deno.test("requires at least one target", () => {
  assertThrows(
    () => validatePackageRequest({ ...validRequest, targets: [] }),
    InvalidPackageRequestError,
    "Select at least one target platform.",
  );
});

Deno.test("rejects duplicate targets", () => {
  assertThrows(
    () =>
      validatePackageRequest({
        ...validRequest,
        targets: ["linux-x86_64", "linux-x86_64"],
      }),
    InvalidPackageRequestError,
    "Target platforms must be unique.",
  );
});

Deno.test("rejects unsafe empty or padded values", () => {
  assertThrows(
    () => validatePackageRequest({ ...validRequest, command: " example-app" }),
    InvalidPackageRequestError,
    "Application command cannot begin or end with whitespace.",
  );
});

Deno.test("rejects application names that are unsafe as directory names", () => {
  assertThrows(
    () => validatePackageRequest({ ...validRequest, applicationName: "../Example" }),
    InvalidPackageRequestError,
    "Application name may contain only",
  );
});
