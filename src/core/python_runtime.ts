import {
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { isNotFound, makeTempDir } from "../platform/fs.ts";
import { join } from "node:path";
import type { PythonDistribution } from "./python_distribution.ts";
import { bundlrCacheDirectory, sha256 } from "../platform/uv.ts";
import { runCommandOutput } from "./process.ts";

export class PythonRuntimeError extends Error {
  override readonly name = "PythonRuntimeError";
}

export async function materializePythonRuntime(
  distribution: PythonDistribution,
  destination: string,
  signal?: AbortSignal,
): Promise<void> {
  const cache =
    process.env["BUNDLR_PYTHON_CACHE_DIRECTORY"] ||
    join(bundlrCacheDirectory(), "python");
  const key = await sha256(
    new TextEncoder().encode(
      `${distribution.archiveUrl}\n${distribution.sha256}`,
    ),
  );
  const archivePath = join(cache, `${key}.tar.gz`);
  signal?.throwIfAborted();
  let cached: Uint8Array | undefined;
  try {
    if ((await lstat(archivePath)).isFile())
      cached = await readFile(archivePath);
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }
  if (cached === undefined || (await sha256(cached)) !== distribution.sha256) {
    const archive = await download(distribution.archiveUrl, signal);
    await verifySha256(archive, distribution.sha256);
    await mkdir(cache, { recursive: true });
    const temporary = await makeTempDir({ dir: cache, prefix: ".python-" });
    try {
      const stage = join(temporary, "python.tar.gz");
      await writeFile(stage, archive, { flag: "wx" });
      await rename(stage, archivePath);
    } finally {
      await rm(temporary, { recursive: true });
    }
  }
  signal?.throwIfAborted();
  await mkdir(destination, { recursive: true });
  await extractArchive(archivePath, destination, signal);
  await requireFile(join(destination, distribution.executablePath));
}

async function download(url: URL, signal?: AbortSignal): Promise<Uint8Array> {
  const response = await fetch(url, { redirect: "follow", signal });
  if (!response.ok) {
    throw new PythonRuntimeError(
      `Python runtime download failed (${response.status}): ${url}`,
    );
  }
  return new Uint8Array(await response.arrayBuffer());
}

async function verifySha256(
  bytes: Uint8Array,
  expected: string,
): Promise<void> {
  const actual = await sha256(bytes);
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
    throw new PythonRuntimeError(
      `Could not extract the Python runtime: ${output.stderr.trim()}`,
    );
  }
}

async function requireFile(path: string): Promise<void> {
  try {
    const info = await stat(path);
    if (info.isFile()) return;
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }
  throw new PythonRuntimeError(
    `Python runtime is missing its executable: ${path}`,
  );
}
