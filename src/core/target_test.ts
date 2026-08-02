import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import { currentTarget, requireNativeTarget, UnsupportedTargetError } from "./target.ts";

Deno.test("maps supported native build targets", () => {
  assertEquals(currentTarget("linux", "x86_64"), "linux-x86_64");
  assertEquals(currentTarget("darwin", "aarch64"), "macos-arm64");
  assertEquals(currentTarget("darwin", "x86_64"), "macos-x86_64");
  assertEquals(currentTarget("windows", "x86_64"), "windows-x86_64");
});

Deno.test("rejects an unsupported host combination", () => {
  assertThrows(
    () => currentTarget("windows", "aarch64"),
    UnsupportedTargetError,
    "does not support packaging on windows-aarch64",
  );
});

Deno.test("accepts one matching native target", () => {
  assertEquals(requireNativeTarget(["linux-x86_64"], "linux-x86_64"), "linux-x86_64");
});

Deno.test("rejects cross-target packaging", () => {
  assertThrows(
    () => requireNativeTarget(["windows-x86_64"], "linux-x86_64"),
    UnsupportedTargetError,
    "can build only linux-x86_64",
  );
});

Deno.test("rejects multiple targets on one worker", () => {
  assertThrows(
    () =>
      requireNativeTarget(
        ["linux-x86_64", "windows-x86_64"],
        "linux-x86_64",
      ),
    UnsupportedTargetError,
    "can build only linux-x86_64",
  );
});
