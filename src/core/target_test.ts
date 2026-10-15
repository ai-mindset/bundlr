import { test } from "bun:test";
import { assertEquals, assertThrows } from "../test/assert.ts";
import { currentTarget, UnsupportedTargetError } from "./target.ts";

test("maps supported native build targets", () => {
  assertEquals(currentTarget("linux", "x64"), "linux-x86_64");
  assertEquals(currentTarget("darwin", "arm64"), "macos-arm64");
  assertEquals(currentTarget("darwin", "x64"), "macos-x86_64");
  assertEquals(currentTarget("win32", "x64"), "windows-x86_64");
});

test("rejects an unsupported host combination", () => {
  assertThrows(
    () => currentTarget("win32", "arm64"),
    UnsupportedTargetError,
    "does not support packaging on win32-arm64",
  );
});
