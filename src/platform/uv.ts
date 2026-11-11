import {
  chmod,
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { createHash } from "node:crypto";
import { gunzipSync } from "node:zlib";
import { join } from "node:path";
import compressedUv from "../../vendor/uv/uv.gz" with { type: "file" };
import provenance from "../../vendor/uv/provenance.json";
import { currentTarget } from "../core/target.ts";
import { UV_CHECKSUM_MANIFEST_SHA256, UV_VERSION } from "../uv_version.ts";
import { isNotFound, makeTempDir } from "./fs.ts";
import { runCommandOutput } from "../core/process.ts";

export async function sha256(bytes: Uint8Array): Promise<string> {
  return createHash("sha256").update(bytes).digest("hex");
}
export async function resolveUvExecutable(): Promise<string> {
  if (
    provenance.version !== UV_VERSION ||
    provenance.target !== currentTarget() ||
    provenance.manifestSha256 !== UV_CHECKSUM_MANIFEST_SHA256
  ) {
    throw new Error(
      "Embedded uv provenance does not match the pinned host release.",
    );
  }
  const expected = provenance.executableSha256;
  const override = process.env.BUNDLR_UV_EXECUTABLE;
  if (override !== undefined) {
    if (!(await matches(override, expected)))
      throw new Error(
        "BUNDLR_UV_EXECUTABLE must match the checksum-pinned host uv binary.",
      );
    return override;
  }
  const directory = join(bundlrCacheDirectory(), UV_VERSION, currentTarget());
  const destination = join(
    directory,
    process.platform === "win32" ? "uv.exe" : "uv",
  );
  if (!(await matches(destination, expected))) {
    const binary = gunzipSync(await Bun.file(compressedUv).arrayBuffer());
    if ((await sha256(binary)) !== expected)
      throw new Error("Embedded uv failed SHA-256 verification.");
    await mkdir(directory, { recursive: true });
    const stage = await makeTempDir({ dir: directory, prefix: ".uv-" });
    try {
      const path = join(stage, "uv");
      await writeFile(path, binary, { flag: "wx", mode: 0o755 });
      await rename(path, destination);
    } finally {
      await rm(stage, { recursive: true });
    }
    if (!(await matches(destination, expected)))
      throw new Error("Cached uv failed SHA-256 verification.");
  }
  if (
    process.platform !== "win32" &&
    ((await lstat(destination)).mode & 0o111) === 0
  )
    await chmod(destination, 0o755);
  return destination;
}
async function matches(path: string, expected: string): Promise<boolean> {
  try {
    return (
      (await lstat(path)).isFile() &&
      (await sha256(await readFile(path))) === expected
    );
  } catch (error) {
    if (isNotFound(error)) return false;
    throw error;
  }
}
export async function diagnoseUv(): Promise<string> {
  const output = await runCommandOutput(await resolveUvExecutable(), [
    "--version",
  ]);
  const version = output.stdout.trim();
  if (!output.success || !version.startsWith("uv " + UV_VERSION + " "))
    throw new Error(
      "uv diagnostic failed: " + (version || output.stderr.trim()),
    );
  return version;
}
export function bundlrCacheDirectory(): string {
  if (process.env.BUNDLR_CACHE_DIRECTORY)
    return process.env.BUNDLR_CACHE_DIRECTORY;
  if (process.platform === "win32")
    return join(required("LOCALAPPDATA"), "Bundlr/runtime");
  const home = required("HOME");
  if (process.platform === "darwin")
    return join(home, "Library/Caches/bundlr/runtime");
  return join(
    process.env.XDG_CACHE_HOME || join(home, ".cache"),
    "bundlr/runtime",
  );
}
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(name + " is required.");
  return value;
}
