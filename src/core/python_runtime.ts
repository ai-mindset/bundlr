import { join } from "jsr:@std/path@1.1.2";
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

  const temporaryDirectory = await Deno.makeTempDir({ prefix: "bundlr-python-" });
  try {
    const archivePath = join(temporaryDirectory, "python.tar.gz");
    await Deno.writeFile(archivePath, archive, { createNew: true });
    await Deno.mkdir(destination, { recursive: true });
    await extractArchive(archivePath, destination, signal);
    await requireFile(join(destination, distribution.executablePath));
  } finally {
    await Deno.remove(temporaryDirectory, { recursive: true });
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
  const output = await new Deno.Command("tar", {
    args: ["-xzf", archive, "-C", destination, "--strip-components=1"],
    stdin: "null",
    stdout: "null",
    stderr: "piped",
    signal,
  }).output();
  if (!output.success) {
    throw new PythonRuntimeError(
      `Could not extract the Python runtime: ${new TextDecoder().decode(output.stderr).trim()}`,
    );
  }
}

async function requireFile(path: string): Promise<void> {
  try {
    const stat = await Deno.stat(path);
    if (stat.isFile) return;
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  throw new PythonRuntimeError(`Python runtime is missing its executable: ${path}`);
}
