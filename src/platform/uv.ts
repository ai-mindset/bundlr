import { UV_CHECKSUM_MANIFEST_SHA256, UV_VERSION } from "../uv_version.ts";
import { runCommandOutput } from "./command.ts";
import { ensureUvRelease, hostUvTarget, type UvDownloadOptions } from "./uv_release.ts";

export async function resolveUvExecutable(options: UvDownloadOptions = {}): Promise<string> {
  const override = process.env["BUNDLR_UV_EXECUTABLE"];
  if (override !== undefined) return override;

  return ensureUvRelease(
    {
      version: UV_VERSION,
      baseUrl: `https://github.com/astral-sh/uv/releases/download/${UV_VERSION}`,
      checksumManifestSha256: UV_CHECKSUM_MANIFEST_SHA256,
    },
    hostUvTarget(),
    cacheDirectory(),
    options,
  );
}

export async function diagnoseUv(options: UvDownloadOptions = {}): Promise<string> {
  const executable = await resolveUvExecutable(options);
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
