import { readFile, writeFile, mkdir, chmod, rename, rm, lstat } from "node:fs/promises";
import { isNotFound, readTextFile } from "./fs.ts";
import { runCommandOutput } from "./command.ts";
import { UV_VERSION } from "../uv_version.ts";

export async function resolveUvExecutable(): Promise<string> {
  const override = process.env["BUNDLR_UV_EXECUTABLE"];
  if (override !== undefined) return override;

  const executableName = process.platform === "win32" ? "uv.exe" : "uv";
  const binaryAsset = Bun.embeddedFiles.find(
    (file) => (file as File).name === `uv/${executableName}`,
  );
  const checksumAsset = Bun.embeddedFiles.find(
    (file) => (file as File).name === `uv/${executableName}.sha256`,
  );
  let binary: Uint8Array;
  let expectedChecksum: string;
  if (binaryAsset !== undefined || checksumAsset !== undefined) {
    if (binaryAsset === undefined || checksumAsset === undefined) {
      throw new Error("The compiled Bundlr executable is missing a bundled uv file.");
    }
    [binary, expectedChecksum] = await Promise.all([binaryAsset.bytes(), checksumAsset.text()]);
  } else {
    try {
      [binary, expectedChecksum] = await Promise.all([
        readFile(new URL(`../../vendor/uv/${executableName}`, import.meta.url)),
        readTextFile(new URL(`../../vendor/uv/${executableName}.sha256`, import.meta.url)),
      ]);
    } catch (error) {
      if (isNotFound(error)) {
        throw new Error("Bundled uv is missing. Run bun run prepare:uv first.", { cause: error });
      }
      throw error;
    }
  }
  await verifyChecksum(binary, expectedChecksum.trim());
  return installBundledUv(binary, executableName);
}

export async function diagnoseUv(): Promise<string> {
  const executable = await resolveUvExecutable();
  const output = await runCommandOutput(executable, ["--version"]);
  if (!output.success) {
    throw new Error(`uv diagnostic failed: ${output.stderr.trim()}`);
  }
  const version = output.stdout.trim();
  if (!version.startsWith(`uv ${UV_VERSION} `)) {
    throw new Error(`Expected uv ${UV_VERSION}, received ${version || "no version output"}.`);
  }
  return version;
}

export async function installBundledUv(
  binary: Uint8Array,
  executableName: string,
  destinationDirectory = cacheDirectory(),
): Promise<string> {
  const destination = `${destinationDirectory}/${UV_VERSION}/${executableName}`;
  const expectedChecksum = await sha256(binary);
  try {
    const cached = await lstat(destination);
    if (cached.isFile() && (await sha256(await readFile(destination))) === expectedChecksum) {
      if (process.platform !== "win32" && (cached.mode & 0o111) === 0) {
        await chmod(destination, 0o755);
      }
      return destination;
    }
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }

  await mkdir(`${destinationDirectory}/${UV_VERSION}`, { recursive: true });
  const temporary = `${destination}.${crypto.randomUUID()}.tmp`;
  try {
    await writeFile(temporary, binary, { flag: "wx", mode: 0o755 });
    if (process.platform !== "win32") await chmod(temporary, 0o755);
    // rename atomically replaces a corrupt cached copy, including one left by
    // an interrupted or externally modified prior run.
    await rename(temporary, destination);
  } finally {
    await rm(temporary).catch((error) => {
      if (!isNotFound(error)) throw error;
    });
  }
  await verifyChecksum(await readFile(destination), expectedChecksum);
  return destination;
}

async function verifyChecksum(binary: Uint8Array, expected: string): Promise<void> {
  if (!/^[a-fA-F0-9]{64}$/.test(expected)) {
    throw new Error("The bundled uv checksum is invalid.");
  }
  const actual = await sha256(binary);
  if (actual !== expected.toLowerCase()) {
    throw new Error("The bundled uv executable failed checksum verification.");
  }
}

async function sha256(binary: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(binary)));
  const actual = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return actual;
}

function cacheDirectory(): string {
  switch (process.platform) {
    case "win32":
      return `${requiredEnvironment("LOCALAPPDATA")}\\Bundlr\\runtime`;
    case "darwin":
      return `${requiredEnvironment("HOME")}/Library/Caches/bundlr/runtime`;
    default: {
      const xdgCache = process.env["XDG_CACHE_HOME"];
      return `${xdgCache ?? `${requiredEnvironment("HOME")}/.cache`}/bundlr/runtime`;
    }
  }
}

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`Required environment variable ${name} is not set.`);
  }
  return value;
}
