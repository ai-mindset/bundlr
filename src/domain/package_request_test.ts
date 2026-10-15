import { test } from "bun:test";
import { assertEquals, assertThrows } from "../test/assert.ts";
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

test("accepts a complete package request", () => {
  assertEquals(validatePackageRequest(validRequest), validRequest);
});

test("requires at least one target", () => {
  assertThrows(
    () => validatePackageRequest({ ...validRequest, targets: [] }),
    InvalidPackageRequestError,
    "Select at least one target platform.",
  );
});

test("rejects duplicate targets", () => {
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

test("rejects unsafe empty or padded values", () => {
  assertThrows(
    () => validatePackageRequest({ ...validRequest, command: " example-app" }),
    InvalidPackageRequestError,
    "Application command cannot begin or end with whitespace.",
  );
});

test("rejects application names that are unsafe as directory names", () => {
  assertThrows(
    () => validatePackageRequest({ ...validRequest, applicationName: "../Example" }),
    InvalidPackageRequestError,
    "Application name may contain only",
  );
});
