import { test } from "bun:test";
import { mkdir, rm } from "node:fs/promises";
import { makeTempDir, readTextFile, writeTextFile } from "../platform/fs.ts";
import { assertEquals, assertMatch } from "../test/assert.ts";
import { writeSupplyChainFiles } from "./supply_chain.ts";

test("writes dependency, licence, and file-hash evidence", async () => {
  const root = await makeTempDir({ prefix: "bundlr-supply-test-" });
  try {
    const metadata = `${root}/packages/example-1.2.3.dist-info`;
    await mkdir(metadata, { recursive: true });
    await mkdir(`${root}/runtime`, { recursive: true });
    await writeTextFile(`${metadata}/METADATA`, "Name: example\nVersion: 1.2.3\n");
    await writeTextFile(`${metadata}/LICENSE`, "Example licence\n");
    await writeTextFile(`${root}/runtime/LICENSE.txt`, "Python licence\n");

    await writeSupplyChainFiles(root, `${root}/packages`);

    assertEquals(JSON.parse(await readTextFile(`${root}/bundlr-dependencies.json`)).dependencies, [
      { name: "example", version: "1.2.3" },
    ]);
    assertMatch(await readTextFile(`${root}/THIRD_PARTY_LICENSES.txt`), /Example licence/);
    assertMatch(await readTextFile(`${root}/SHA256SUMS`), /packages\/example-1\.2\.3/);
  } finally {
    await rm(root, { recursive: true });
  }
});
