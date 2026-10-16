import { chmod, lstat, mkdir, opendir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import JSZip from "jszip";
import { runCommandOutput } from "./command.ts";
import { isNotFound, makeTempDir } from "./fs.ts";

export interface UvRelease {
  readonly version: string;
  readonly baseUrl: string;
  readonly checksumManifestSha256: string;
}

export interface UvDownloadOptions {
  readonly signal?: AbortSignal;
  readonly fetch?: UvFetch;
  readonly onDownload?: () => void;
}

export type UvFetch = (url: string, init?: RequestInit) => Promise<Response>;

const artifacts: Readonly<Record<string, string>> = {
  "aarch64-apple-darwin": "uv-aarch64-apple-darwin.tar.gz",
  "aarch64-unknown-linux-gnu": "uv-aarch64-unknown-linux-gnu.tar.gz",
  "x86_64-apple-darwin": "uv-x86_64-apple-darwin.tar.gz",
  "x86_64-pc-windows-msvc": "uv-x86_64-pc-windows-msvc.zip",
  "x86_64-unknown-linux-gnu": "uv-x86_64-unknown-linux-gnu.tar.gz",
};

class MissingFileError extends Error {}

export async function ensureUvRelease(
  release: UvRelease,
  target: string,
  cacheRoot: string,
  options: UvDownloadOptions = {},
): Promise<string> {
  const artifact = artifacts[target];
  if (artifact === undefined) throw new Error(`Unsupported uv target: ${target}`);
  options.signal?.throwIfAborted();

  const executableName = target.includes("windows") ? "uv.exe" : "uv";
  const versionDirectory = join(cacheRoot, release.version);
  const destination = join(versionDirectory, executableName);
  const archivePath = join(versionDirectory, artifact);
  const manifestPath = join(versionDirectory, "sha256.sum");
  let archive = await cachedVerifiedArchive(release, artifact, manifestPath, archivePath);
  if (archive === undefined) {
    options.onDownload?.();
    const download = options.fetch ?? fetch;
    const checksums = await downloadBytes(
      `${release.baseUrl}/sha256.sum`,
      download,
      options.signal,
    );
    await verifySha256(checksums, release.checksumManifestSha256, "uv checksum manifest");
    const archiveChecksum = parseChecksum(new TextDecoder().decode(checksums), artifact);
    archive = await downloadBytes(`${release.baseUrl}/${artifact}`, download, options.signal);
    await verifySha256(archive, archiveChecksum, artifact);
    await cacheVerifiedArchive(versionDirectory, manifestPath, archivePath, checksums, archive);
  }

  options.signal?.throwIfAborted();
  const temporaryDirectory = await makeTempDir({ prefix: "bundlr-uv-" });
  try {
    const binary = await extractExecutable(
      archive,
      artifact,
      executableName,
      temporaryDirectory,
      options.signal,
    );
    options.signal?.throwIfAborted();
    const binaryChecksum = await sha256(binary);
    if (await cachedExecutableIsValid(destination, binaryChecksum, target)) return destination;
    await mkdir(versionDirectory, { recursive: true });
    const stagingDirectory = await makeTempDir({ prefix: ".bundlr-uv-", dir: versionDirectory });
    try {
      const stagedExecutable = join(stagingDirectory, executableName);
      await writeFile(stagedExecutable, binary, { flag: "wx", mode: 0o755 });
      if (!target.includes("windows")) await chmod(stagedExecutable, 0o755);
      await rename(stagedExecutable, destination);
    } finally {
      await rm(stagingDirectory, { recursive: true });
    }

    if (!(await cachedExecutableIsValid(destination, binaryChecksum, target))) {
      throw new Error("The cached uv executable failed SHA-256 verification.");
    }
    return destination;
  } finally {
    await rm(temporaryDirectory, { recursive: true });
  }
}

export function hostUvTarget(): string {
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

async function cachedExecutableIsValid(
  destination: string,
  expectedChecksum: string,
  target: string,
): Promise<boolean> {
  try {
    const file = await lstat(destination);
    if (!file.isFile()) return false;
    if ((await sha256(await readFile(destination))) !== expectedChecksum) return false;
    if (!target.includes("windows") && (file.mode & 0o111) === 0) await chmod(destination, 0o755);
    return true;
  } catch (error) {
    if (isNotFound(error)) return false;
    throw error;
  }
}

async function cachedVerifiedArchive(
  release: UvRelease,
  artifact: string,
  manifestPath: string,
  archivePath: string,
): Promise<Uint8Array | undefined> {
  let checksums: Uint8Array;
  let archive: Uint8Array;
  try {
    [checksums, archive] = await Promise.all([readFile(manifestPath), readFile(archivePath)]);
  } catch (error) {
    if (isNotFound(error)) return undefined;
    throw error;
  }
  try {
    await verifySha256(checksums, release.checksumManifestSha256, "uv checksum manifest");
    const archiveChecksum = parseChecksum(new TextDecoder().decode(checksums), artifact);
    await verifySha256(archive, archiveChecksum, artifact);
    return archive;
  } catch {
    return undefined;
  }
}

async function cacheVerifiedArchive(
  versionDirectory: string,
  manifestPath: string,
  archivePath: string,
  checksums: Uint8Array,
  archive: Uint8Array,
): Promise<void> {
  await mkdir(versionDirectory, { recursive: true });
  const stagingDirectory = await makeTempDir({ prefix: ".bundlr-uv-", dir: versionDirectory });
  try {
    const stagedManifest = join(stagingDirectory, "sha256.sum");
    const stagedArchive = join(stagingDirectory, "archive");
    await writeFile(stagedManifest, checksums, { flag: "wx" });
    await writeFile(stagedArchive, archive, { flag: "wx" });
    await rename(stagedArchive, archivePath);
    await rename(stagedManifest, manifestPath);
  } finally {
    await rm(stagingDirectory, { recursive: true });
  }
}

async function downloadBytes(
  url: string,
  download: UvFetch,
  signal?: AbortSignal,
): Promise<Uint8Array> {
  let response: Response;
  try {
    response = await download(url, { redirect: "follow", signal });
  } catch (error) {
    signal?.throwIfAborted();
    throw new Error(`Could not download uv from ${url}.`, { cause: error });
  }
  if (!response.ok) throw new Error(`uv download failed (${response.status}): ${url}`);
  try {
    return new Uint8Array(await response.arrayBuffer());
  } catch (error) {
    signal?.throwIfAborted();
    throw new Error(`Could not download uv from ${url}.`, { cause: error });
  }
}

async function verifySha256(bytes: Uint8Array, expected: string, label: string): Promise<void> {
  if (!/^[a-fA-F0-9]{64}$/.test(expected)) throw new Error(`Invalid SHA-256 for ${label}.`);
  const actual = await sha256(bytes);
  if (actual !== expected.toLowerCase()) {
    throw new Error(
      `${label} failed SHA-256 verification: expected ${expected}, received ${actual}`,
    );
  }
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function parseChecksum(manifest: string, artifact: string): string {
  for (const line of manifest.split(/\r?\n/)) {
    const match = /^([a-fA-F0-9]{64})\s+\*?(.+)$/.exec(line.trim());
    if (match?.[2] === artifact) return match[1]!.toLowerCase();
  }
  throw new Error(`No checksum found for ${artifact}.`);
}

async function extractExecutable(
  archive: Uint8Array,
  artifact: string,
  executableName: string,
  temporaryDirectory: string,
  signal?: AbortSignal,
): Promise<Uint8Array> {
  if (artifact.endsWith(".zip")) {
    const zip = await JSZip.loadAsync(archive);
    const entry = Object.values(zip.files).find(
      (candidate) => !candidate.dir && candidate.name.split("/").at(-1) === executableName,
    );
    if (entry === undefined) throw new MissingFileError(`${executableName} was not in uv archive.`);
    return entry.async("uint8array");
  }

  const archivePath = join(temporaryDirectory, artifact);
  await writeFile(archivePath, archive, { flag: "wx" });
  const result = await runCommandOutput(
    "tar",
    ["-xzf", archivePath, "-C", temporaryDirectory],
    signal,
  );
  if (!result.success) throw new Error(`Could not extract uv: ${result.stderr.trim()}`);
  return readFile(await findFile(temporaryDirectory, executableName));
}

async function findFile(directory: string, name: string): Promise<string> {
  for await (const entry of await opendir(directory)) {
    const path = join(directory, entry.name);
    if (entry.isFile() && entry.name === name) return path;
    if (entry.isDirectory()) {
      try {
        return await findFile(path, name);
      } catch (error) {
        if (!(error instanceof MissingFileError)) throw error;
      }
    }
  }
  throw new MissingFileError(`${name} was not in uv archive.`);
}
