import { assertEquals, assertMatch, assertRejects } from "jsr:@std/assert@1.0.19";
import { basename, join } from "jsr:@std/path@1.1.2";
import { createClientArchive } from "./client_archive.ts";

Deno.test("publishes a complete Windows archive and checksum", async () => {
  const outputDirectory = await Deno.makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    await Deno.mkdir(artifactPath);
    await Deno.writeTextFile(join(artifactPath, "payload.txt"), "example payload\n");

    const result = await createClientArchive({ artifactPath, target: "windows-x86_64" });

    assertEquals(result.archivePath, `${artifactPath}.zip`);
    assertEquals(result.checksumPath, `${artifactPath}.zip.sha256`);
    assertMatch(result.sha256, /^[a-f0-9]{64}$/);
    assertEquals(
      await Deno.readTextFile(result.checksumPath),
      `${result.sha256}  ${basename(result.archivePath)}\n`,
    );
    assertEquals(await stagingDirectories(outputDirectory), []);
  } finally {
    await Deno.remove(outputDirectory, { recursive: true });
  }
});

Deno.test("refuses a checksum collision before publishing an archive", async () => {
  const outputDirectory = await Deno.makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    const archivePath = `${artifactPath}.zip`;
    const checksumPath = `${archivePath}.sha256`;
    await Deno.mkdir(artifactPath);
    await Deno.writeTextFile(join(artifactPath, "payload.txt"), "example payload\n");
    await Deno.writeTextFile(checksumPath, "existing checksum\n");

    await assertRejects(
      () => createClientArchive({ artifactPath, target: "windows-x86_64" }),
      Error,
      `Refusing to overwrite the existing archive: ${checksumPath}`,
    );

    assertEquals(await pathExists(archivePath), false);
    assertEquals(await Deno.readTextFile(checksumPath), "existing checksum\n");
    assertEquals(await stagingDirectories(outputDirectory), []);
  } finally {
    await Deno.remove(outputDirectory, { recursive: true });
  }
});

Deno.test("removes staged output when archive creation fails", async () => {
  const outputDirectory = await Deno.makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    await Deno.writeTextFile(artifactPath, "not a directory\n");

    await assertRejects(
      () => createClientArchive({ artifactPath, target: "windows-x86_64" }),
      Error,
    );

    assertEquals(await pathExists(`${artifactPath}.zip`), false);
    assertEquals(await pathExists(`${artifactPath}.zip.sha256`), false);
    assertEquals(await stagingDirectories(outputDirectory), []);
  } finally {
    await Deno.remove(outputDirectory, { recursive: true });
  }
});

async function stagingDirectories(directory: string): Promise<string[]> {
  const names: string[] = [];
  for await (const entry of Deno.readDir(directory)) {
    if (entry.isDirectory && entry.name.startsWith(".bundlr-archive-")) names.push(entry.name);
  }
  return names;
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await Deno.lstat(path);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
}
