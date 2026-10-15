import { writeFile, mkdir, rm, stat } from "node:fs/promises";
import { makeTempDir, isNotFound } from "../platform/fs.ts";
import { join } from "node:path";
import { runCommandOutput } from "../platform/command.ts";
import type { PythonDistribution } from "./python_distribution.ts";

export class PythonRuntimeError extends Error {
  override readonly name = "PythonRuntimeError";
}

export async function materializePythonRuntime(
  distribution: PythonDistribution,
  destination: string,
  signal?: AbortSignal,
): Promise<void> {
  const archive = await download(distribution.archiveUrl, signal);
  await verifySha256(archive, distribution.sha256);

  const temporaryDirectory = await makeTempDir({ prefix: "bundlr-python-" });
  try {
    const archivePath = join(temporaryDirectory, "python.tar.gz");
    await writeFile(archivePath, archive, { flag: "wx" });
    await mkdir(destination, { recursive: true });
    await extractArchive(archivePath, destination, signal);
    await requireFile(join(destination, distribution.executablePath));
  } finally {
    await rm(temporaryDirectory, { recursive: true });
  }
}

async function download(url: URL, signal?: AbortSignal): Promise<Uint8Array> {
  const response = await fetch(url, { redirect: "follow", signal });
  if (!response.ok) {
    throw new PythonRuntimeError(`Python runtime download failed (${response.status}): ${url}`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

async function verifySha256(bytes: Uint8Array, expected: string): Promise<void> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes)));
  const actual = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
  if (actual !== expected) {
    throw new PythonRuntimeError(
      `Python runtime failed SHA-256 verification: expected ${expected}, received ${actual}.`,
    );
  }
}

async function extractArchive(
  archive: string,
  destination: string,
  signal?: AbortSignal,
): Promise<void> {
  const output = await runCommandOutput(
    "tar",
    ["-xzf", archive, "-C", destination, "--strip-components=1"],
    signal,
  );
  if (!output.success) {
    throw new PythonRuntimeError(`Could not extract the Python runtime: ${output.stderr.trim()}`);
  }
}

async function requireFile(path: string): Promise<void> {
  try {
    const fileStats = await stat(path);
    if (fileStats.isFile()) return;
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }
  throw new PythonRuntimeError(`Python runtime is missing its executable: ${path}`);
}
