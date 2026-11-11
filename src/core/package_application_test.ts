import { opendir, rm } from "node:fs/promises";
import { makeTempDir, readTextFile, writeTextFile } from "../platform/fs.ts";
import { test } from "bun:test";
import { assertEquals, assertRejects } from "../test/assert.ts";
import { join } from "node:path";
import { packageApplication, PackagingError } from "./package_application.ts";

test("packaging rejects existing archives before creating staging or fetching Python", async () => {
  const outputDirectory = await makeTempDir({
    prefix: "bundlr-collision-test-",
  });
  try {
    const existing = "Example-linux-x86_64.tar.gz";
    await writeTextFile(join(outputDirectory, existing), "original archive");
    await assertRejects(
      () =>
        packageApplication({
          source: { kind: "pypi", requirement: "example==1.0.0" },
          applicationName: "Example",
          command: "example",
          applicationKind: "console",
          python: "3.12",
          targets: ["linux-x86_64"],
          outputDirectory,
        }),
      PackagingError,
      "Refusing to overwrite",
    );
    assertEquals(
      await readTextFile(join(outputDirectory, existing)),
      "original archive",
    );
    const entries = [];
    for await (const entry of await opendir(outputDirectory))
      entries.push(entry.name);
    assertEquals(entries, [existing]);
  } finally {
    await rm(outputDirectory, { recursive: true });
  }
});
