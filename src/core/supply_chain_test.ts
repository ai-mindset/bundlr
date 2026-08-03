import { assertEquals, assertMatch } from "jsr:@std/assert@1.0.19";
import { writeSupplyChainFiles } from "./supply_chain.ts";

Deno.test("writes dependency, licence, and file-hash evidence", async () => {
  const root = await Deno.makeTempDir({ prefix: "bundlr-supply-test-" });
  try {
    const metadata = `${root}/packages/example-1.2.3.dist-info`;
    await Deno.mkdir(metadata, { recursive: true });
    await Deno.mkdir(`${root}/runtime`, { recursive: true });
    await Deno.writeTextFile(`${metadata}/METADATA`, "Name: example\nVersion: 1.2.3\n");
    await Deno.writeTextFile(`${metadata}/LICENSE`, "Example licence\n");
    await Deno.writeTextFile(`${root}/runtime/LICENSE.txt`, "Python licence\n");

    await writeSupplyChainFiles(root, `${root}/packages`);

    assertEquals(
      JSON.parse(await Deno.readTextFile(`${root}/bundlr-dependencies.json`)).dependencies,
      [{ name: "example", version: "1.2.3" }],
    );
    assertMatch(await Deno.readTextFile(`${root}/THIRD_PARTY_LICENSES.txt`), /Example licence/);
    assertMatch(await Deno.readTextFile(`${root}/SHA256SUMS`), /packages\/example-1\.2\.3/);
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
