import { rm } from "node:fs/promises";
import { makeTempDir, writeTextFile } from "../platform/fs.ts";
import { test } from "bun:test";
import { assertEquals, assertRejects } from "../test/assert.ts";
import {
  NonPortableGitPackageError,
  parseWheelRequirements,
  requirePortableGitWheel,
} from "./wheel_metadata.ts";

test("reads repeated and folded wheel requirements", () => {
  assertEquals(
    parseWheelRequirements(
      "Metadata-Version: 2.4\n" +
        "Name: example\n" +
        "Requires-Dist: click>=8\n" +
        "Requires-Dist: colorama>=0.4;\n  sys_platform == 'win32'\n\nDescription\n",
    ),
    ["click>=8", "colorama>=0.4;sys_platform == 'win32'"],
  );
});

test("returns no requirements when metadata has none", () => {
  assertEquals(
    parseWheelRequirements("Metadata-Version: 2.4\nName: example\n"),
    [],
  );
});

test("accepts a pure platform-independent Git wheel", async () => {
  await withWheel(
    "Root-Is-Purelib: true\nTag: py3-none-any\n",
    requirePortableGitWheel,
  );
});

test("rejects a host-native Git wheel", async () => {
  await assertRejects(
    () =>
      withWheel(
        "Root-Is-Purelib: false\nTag: cp312-cp312-manylinux_2_28_x86_64\n",
        requirePortableGitWheel,
      ),
    NonPortableGitPackageError,
    "platform-specific wheel",
  );
});

async function withWheel(
  contents: string,
  operation: (directory: string) => Promise<void>,
): Promise<void> {
  const directory = await makeTempDir({ prefix: "bundlr-wheel-test-" });
  try {
    await writeTextFile(`${directory}/WHEEL`, contents);
    await operation(directory);
  } finally {
    await rm(directory, { recursive: true });
  }
}
