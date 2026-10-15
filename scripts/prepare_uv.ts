import { readFile, writeFile, mkdir, copyFile, chmod, rm, opendir } from "node:fs/promises";
import { makeTempDir, writeTextFile } from "../src/platform/fs.ts";
import JSZip from "jszip";
import { runCommandOutput } from "../src/platform/command.ts";
import { UV_CHECKSUM_MANIFEST_SHA256, UV_VERSION } from "../src/uv_version.ts";

const RELEASE_BASE = `https://github.com/astral-sh/uv/releases/download/${UV_VERSION}`;

class MissingFileError extends Error {}

const artifacts: Readonly<Record<string, string>> = {
  "aarch64-apple-darwin": "uv-aarch64-apple-darwin.tar.gz",
  "aarch64-unknown-linux-gnu": "uv-aarch64-unknown-linux-gnu.tar.gz",
  "x86_64-apple-darwin": "uv-x86_64-apple-darwin.tar.gz",
  "x86_64-pc-windows-msvc": "uv-x86_64-pc-windows-msvc.zip",
  "x86_64-unknown-linux-gnu": "uv-x86_64-unknown-linux-gnu.tar.gz",
};

if (import.meta.main) await main(process.argv.slice(2));

async function main(args: readonly string[]): Promise<void> {
  const target = args[0] ?? hostTarget();
  const artifact = artifacts[target];
  if (artifact === undefined) throw new Error(`Unsupported uv target: ${target}`);

  const temporaryDirectory = await makeTempDir({ prefix: "bundlr-uv-" });
  try {
    const checksums = await download(`${RELEASE_BASE}/sha256.sum`);
    await verify(checksums, UV_CHECKSUM_MANIFEST_SHA256, "uv checksum manifest");
    const expectedArtifactChecksum = parseChecksum(new TextDecoder().decode(checksums), artifact);

    const archive = await download(`${RELEASE_BASE}/${artifact}`);
    await verify(archive, expectedArtifactChecksum, artifact);
    const archivePath = `${temporaryDirectory}/${artifact}`;
    await writeFile(archivePath, archive);
    const executableName = target.includes("windows") ? "uv.exe" : "uv";
    if (artifact.endsWith(".zip")) {
      await extractZipExecutable(archive, temporaryDirectory, executableName);
    } else {
      await extract(archivePath, temporaryDirectory);
    }
    const extractedExecutable = await findFile(temporaryDirectory, executableName);
    const outputDirectory = "vendor/uv";
    const outputExecutable = `${outputDirectory}/${executableName}`;
    await mkdir(outputDirectory, { recursive: true });
    await copyFile(extractedExecutable, outputExecutable);
    if (!target.includes("windows")) await chmod(outputExecutable, 0o755);

    const executable = await readFile(outputExecutable);
    await writeTextFile(`${outputExecutable}.sha256`, `${await sha256(executable)}\n`);
    console.log(`Prepared uv ${UV_VERSION} for ${target} at ${outputExecutable}`);
  } finally {
    await rm(temporaryDirectory, { recursive: true });
  }
}

async function download(url: string): Promise<Uint8Array> {
  const response = await fetch(url, { redirect: "follow" });
  if (!response.ok) throw new Error(`Download failed (${response.status}): ${url}`);
  return new Uint8Array(await response.arrayBuffer());
}

async function verify(bytes: Uint8Array, expected: string, label: string): Promise<void> {
  const actual = await sha256(bytes);
  if (actual !== expected.toLowerCase()) {
    throw new Error(
      `${label} failed SHA-256 verification: expected ${expected}, received ${actual}`,
    );
  }
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const input = Uint8Array.from(bytes);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function parseChecksum(manifest: string, artifact: string): string {
  for (const line of manifest.split(/\r?\n/)) {
    const match = /^([a-fA-F0-9]{64})\s+\*?(.+)$/.exec(line.trim());
    if (match?.[2] === artifact) return match[1]!.toLowerCase();
  }
  throw new Error(`No checksum found for ${artifact}.`);
}

async function extractZipExecutable(
  archive: Uint8Array,
  destination: string,
  name: string,
): Promise<void> {
  const zip = await JSZip.loadAsync(archive);
  const entry = Object.values(zip.files).find(
    (candidate) => !candidate.dir && candidate.name.split("/").at(-1) === name,
  );
  if (entry === undefined) throw new MissingFileError(`${name} was not present in the uv archive.`);
  await writeFile(`${destination}/${name}`, await entry.async("uint8array"), { flag: "wx" });
}

async function extract(archive: string, destination: string): Promise<void> {
  const result = await runCommandOutput("tar", ["-xf", archive, "-C", destination]);
  if (!result.success) {
    throw new Error(`Could not extract uv: ${result.stderr.trim()}`);
  }
}

async function findFile(directory: string, name: string): Promise<string> {
  for await (const entry of await opendir(directory)) {
    const path = `${directory}/${entry.name}`;
    if (entry.isFile() && entry.name === name) return path;
    if (entry.isDirectory()) {
      try {
        return await findFile(path, name);
      } catch (error) {
        if (!(error instanceof MissingFileError)) throw error;
      }
    }
  }
  throw new MissingFileError(`${name} was not present in the uv archive.`);
}

function hostTarget(): string {
  const architecture = process.arch === "arm64" ? "aarch64" : "x86_64";
  switch (process.platform) {
    case "darwin":
      return `${architecture}-apple-darwin`;
    case "win32":
      if (architecture !== "x86_64") throw new Error("Windows ARM64 is not currently supported.");
      return "x86_64-pc-windows-msvc";
    case "linux":
      return `${architecture}-unknown-linux-gnu`;
    default:
      throw new Error(`Unsupported host OS: ${process.platform}`);
  }
}
