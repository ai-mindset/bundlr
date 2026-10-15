import { test } from "bun:test";
import { mkdir, rm, lstat, opendir, readFile, chmod } from "node:fs/promises";
import { makeTempDir, isNotFound, readTextFile, writeTextFile } from "../platform/fs.ts";
import { assertEquals, assertMatch, assertRejects } from "../test/assert.ts";
import JSZip from "jszip";
import { basename, join } from "node:path";
import { createClientArchive } from "./client_archive.ts";

test("publishes a complete Windows archive and checksum", async () => {
  const outputDirectory = await makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    await mkdir(artifactPath);
    await writeTextFile(join(artifactPath, "payload.txt"), "example payload\n");
    if (process.platform !== "win32") await chmod(join(artifactPath, "payload.txt"), 0o755);

    const result = await createClientArchive({ artifactPath, target: "windows-x86_64" });

    assertEquals(result.archivePath, `${artifactPath}.zip`);
    assertEquals(result.checksumPath, `${artifactPath}.zip.sha256`);
    assertMatch(result.sha256, /^[a-f0-9]{64}$/);
    assertEquals(
      await readTextFile(result.checksumPath),
      `${result.sha256}  ${basename(result.archivePath)}\n`,
    );
    assertEquals(await stagingDirectories(outputDirectory), []);
    const zip = await JSZip.loadAsync(await readFile(result.archivePath));
    const payload = zip.file("Example-windows-x86_64/payload.txt");
    assertEquals(await payload?.async("string"), "example payload\n");
    if (process.platform !== "win32") {
      const permissions = payload?.unixPermissions;
      const mode = typeof permissions === "number" ? permissions : parseInt(permissions ?? "0", 8);
      assertEquals(mode & 0o777, 0o755);
    }
  } finally {
    await rm(outputDirectory, { recursive: true });
  }
});

test("refuses a checksum collision before publishing an archive", async () => {
  const outputDirectory = await makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    const archivePath = `${artifactPath}.zip`;
    const checksumPath = `${archivePath}.sha256`;
    await mkdir(artifactPath);
    await writeTextFile(join(artifactPath, "payload.txt"), "example payload\n");
    await writeTextFile(checksumPath, "existing checksum\n");

    await assertRejects(
      () => createClientArchive({ artifactPath, target: "windows-x86_64" }),
      Error,
      `Refusing to overwrite the existing archive: ${checksumPath}`,
    );

    assertEquals(await pathExists(archivePath), false);
    assertEquals(await readTextFile(checksumPath), "existing checksum\n");
    assertEquals(await stagingDirectories(outputDirectory), []);
  } finally {
    await rm(outputDirectory, { recursive: true });
  }
});

test("removes staged output when archive creation fails", async () => {
  const outputDirectory = await makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    await writeTextFile(artifactPath, "not a directory\n");

    await assertRejects(
      () => createClientArchive({ artifactPath, target: "windows-x86_64" }),
      Error,
    );

    assertEquals(await pathExists(`${artifactPath}.zip`), false);
    assertEquals(await pathExists(`${artifactPath}.zip.sha256`), false);
    assertEquals(await stagingDirectories(outputDirectory), []);
  } finally {
    await rm(outputDirectory, { recursive: true });
  }
});

test("concurrent builds publish an archive name only once", async () => {
  const outputDirectory = await makeTempDir({ prefix: "bundlr-archive-test-" });
  try {
    const artifactPath = join(outputDirectory, "Example-windows-x86_64");
    await mkdir(artifactPath);
    await writeTextFile(join(artifactPath, "payload.txt"), "example payload\n");

    const attempts = await Promise.allSettled([
      createClientArchive({ artifactPath, target: "windows-x86_64" }),
      createClientArchive({ artifactPath, target: "windows-x86_64" }),
    ]);
    assertEquals(attempts.filter((attempt) => attempt.status === "fulfilled").length, 1);
    assertEquals(attempts.filter((attempt) => attempt.status === "rejected").length, 1);
    const archivePath = `${artifactPath}.zip`;
    const zip = await JSZip.loadAsync(await readFile(archivePath));
    assertEquals(
      await zip.file("Example-windows-x86_64/payload.txt")?.async("string"),
      "example payload\n",
    );
    assertEquals(await stagingDirectories(outputDirectory), []);
  } finally {
    await rm(outputDirectory, { recursive: true });
  }
});

async function stagingDirectories(directory: string): Promise<string[]> {
  const names: string[] = [];
  for await (const entry of await opendir(directory)) {
    if (entry.isDirectory() && entry.name.startsWith(".bundlr-archive-")) names.push(entry.name);
  }
  return names;
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (isNotFound(error)) return false;
    throw error;
  }
}
