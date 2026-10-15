import { test } from "bun:test";
import { chmod, readFile, rm, stat, writeFile } from "node:fs/promises";
import { assertEquals } from "../test/assert.ts";
import { makeTempDir } from "./fs.ts";
import { installBundledUv } from "./uv.ts";

test("replaces a corrupt cached uv executable with verified bytes", async () => {
  const cache = await makeTempDir({ prefix: "bundlr-uv-cache-test-" });
  const binary = new TextEncoder().encode("verified uv bytes");
  try {
    const path = await installBundledUv(binary, "uv", cache);
    await writeFile(path, "corrupt");
    assertEquals(await installBundledUv(binary, "uv", cache), path);
    assertEquals(await readFile(path), binary);
    if (process.platform !== "win32") {
      await chmod(path, 0o644);
      await installBundledUv(binary, "uv", cache);
      assertEquals((await stat(path)).mode & 0o777, 0o755);
    }
  } finally {
    await rm(cache, { recursive: true });
  }
});
