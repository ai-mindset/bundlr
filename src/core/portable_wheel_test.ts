import { test } from "bun:test";
import { rm } from "node:fs/promises";
import { makeTempDir, writeTextFile } from "../platform/fs.ts";
import { assertRejects } from "../test/assert.ts";
import { NonPortableGitPackageError, requirePortableGitWheel } from "./portable_wheel.ts";

test("accepts a pure platform-independent Git wheel", async () => {
  await withWheel("Root-Is-Purelib: true\nTag: py3-none-any\n", requirePortableGitWheel);
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
