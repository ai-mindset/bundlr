import { ZipWriter } from "jsr:@zip-js/zip-js@2.8.34";
import { basename, dirname, join, relative } from "jsr:@std/path@1.1.2";
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
  await requireAbsent(archivePath);
  if (result.target === "windows-x86_64") {
    await createZip(result.artifactPath, archivePath);
  } else {
    await createTarGz(result.artifactPath, archivePath);
  }
  const sha256 = await fileSha256(archivePath);
  const checksumPath = `${archivePath}.sha256`;
  await Deno.writeTextFile(checksumPath, `${sha256}  ${basename(archivePath)}\n`, {
    createNew: true,
  });
  return { archivePath, checksumPath, sha256 };
}

async function createZip(source: string, destination: string): Promise<void> {
  const output = await Deno.open(destination, { createNew: true, write: true });
  const writer = new ZipWriter(output.writable);
  try {
    for await (const path of filesIn(source)) {
      const input = await Deno.open(path, { read: true });
      await writer.add(
        join(basename(source), relative(source, path)).replaceAll("\\", "/"),
        input.readable,
      );
    }
    await writer.close();
  } catch (error) {
    await writer.close().catch(() => undefined);
    await Deno.remove(destination).catch(() => undefined);
    throw error;
  }
}

async function* filesIn(directory: string): AsyncGenerator<string> {
  for await (const entry of Deno.readDir(directory)) {
    const path = join(directory, entry.name);
    if (entry.isDirectory) yield* filesIn(path);
    else if (entry.isFile) yield path;
  }
}

async function createTarGz(source: string, destination: string): Promise<void> {
  const output = await new Deno.Command("tar", {
    args: ["-C", dirname(source), "-czf", destination, basename(source)],
    stdin: "null",
    stdout: "null",
    stderr: "piped",
  }).output();
  if (!output.success) {
    await Deno.remove(destination).catch(() => undefined);
    throw new Error(
      `Could not create client archive: ${new TextDecoder().decode(output.stderr).trim()}`,
    );
  }
}

async function fileSha256(path: string): Promise<string> {
  const bytes = await Deno.readFile(path);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function requireAbsent(path: string): Promise<void> {
  try {
    await Deno.lstat(path);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return;
    throw error;
  }
  throw new Error(`Refusing to overwrite the existing archive: ${path}`);
}
