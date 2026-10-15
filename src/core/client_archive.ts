import { link, rm, lstat, opendir } from "node:fs/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { createHash } from "node:crypto";
import { pipeline } from "node:stream/promises";
import { makeTempDir, isNotFound, isAlreadyExists, writeTextFile } from "../platform/fs.ts";
import { runCommandOutput } from "../platform/command.ts";
import JSZip from "jszip";
import { basename, dirname, join, relative } from "node:path";
import type { PackageResult } from "./package_application.ts";

export interface ClientArchive {
  readonly archivePath: string;
  readonly checksumPath: string;
  readonly sha256: string;
}

export async function createClientArchive(result: PackageResult): Promise<ClientArchive> {
  const extension = result.target === "windows-x86_64" ? ".zip" : ".tar.gz";
  const archiveBase = result.artifactPath.endsWith(".app")
    ? result.artifactPath.slice(0, -".app".length)
    : result.artifactPath;
  const archivePath = `${archiveBase}${extension}`;
  const checksumPath = `${archivePath}.sha256`;
  await Promise.all([requireAbsent(archivePath), requireAbsent(checksumPath)]);

  const stagingDirectory = await makeTempDir({
    dir: dirname(archivePath),
    prefix: ".bundlr-archive-",
  });
  const stagedArchive = join(stagingDirectory, basename(archivePath));
  const stagedChecksum = join(stagingDirectory, basename(checksumPath));
  let archivePublished = false;
  let checksumPublished = false;
  try {
    if (result.target === "windows-x86_64") {
      await createZip(result.artifactPath, stagedArchive);
    } else {
      await createTarGz(result.artifactPath, stagedArchive);
    }
    const sha256 = await fileSha256(stagedArchive);
    await writeTextFile(stagedChecksum, `${sha256}  ${basename(archivePath)}\n`, {
      createNew: true,
    });

    await publishNoReplace(stagedArchive, archivePath);
    archivePublished = true;
    await publishNoReplace(stagedChecksum, checksumPath);
    checksumPublished = true;
    return { archivePath, checksumPath, sha256 };
  } catch (error) {
    if (checksumPublished) await rm(checksumPath).catch(() => undefined);
    if (archivePublished) await rm(archivePath).catch(() => undefined);
    throw error;
  } finally {
    await rm(stagingDirectory, { recursive: true }).catch(() => undefined);
  }
}

async function publishNoReplace(stagedPath: string, destination: string): Promise<void> {
  try {
    // The staging directory shares the destination filesystem. A hard link is an
    // atomic create that fails if another build published the name first.
    await link(stagedPath, destination);
  } catch (error) {
    if (isAlreadyExists(error)) {
      throw new Error(`Refusing to overwrite the existing archive: ${destination}`, {
        cause: error,
      });
    }
    throw error;
  }
}

async function createZip(source: string, destination: string): Promise<void> {
  const zip = new JSZip();
  let sourceBytes = 0;
  let entryCount = 0;
  try {
    for await (const path of filesIn(source)) {
      const file = await lstat(path);
      sourceBytes += file.size;
      entryCount++;
      if (sourceBytes > 0xffff_ffff - 64 * 1024 * 1024 || entryCount > 0xffff) {
        throw new Error("The Windows application exceeds the supported ZIP size or entry limit.");
      }
      zip.file(
        join(basename(source), relative(source, path)).replaceAll("\\", "/"),
        createReadStream(path),
        { createFolders: false, date: file.mtime, unixPermissions: file.mode },
      );
    }
    await pipeline(
      zip.generateNodeStream({
        streamFiles: true,
        compression: "DEFLATE",
        platform: process.platform === "win32" ? "DOS" : "UNIX",
      }),
      createWriteStream(destination, { flags: "wx" }),
    );
  } catch (error) {
    await rm(destination).catch(() => undefined);
    throw error;
  }
}

async function* filesIn(directory: string): AsyncGenerator<string> {
  for await (const entry of await opendir(directory)) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* filesIn(path);
    else if (entry.isFile()) yield path;
  }
}

async function createTarGz(source: string, destination: string): Promise<void> {
  const output = await runCommandOutput("tar", [
    "-C",
    dirname(source),
    "-czf",
    destination,
    basename(source),
  ]);
  if (!output.success) {
    await rm(destination).catch(() => undefined);
    throw new Error(`Could not create client archive: ${output.stderr.trim()}`);
  }
}

async function fileSha256(path: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

async function requireAbsent(path: string): Promise<void> {
  try {
    await lstat(path);
  } catch (error) {
    if (isNotFound(error)) return;
    throw error;
  }
  throw new Error(`Refusing to overwrite the existing archive: ${path}`);
}
