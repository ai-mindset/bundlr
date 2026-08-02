import { UV_VERSION } from "../uv_version.ts";

export async function resolveUvExecutable(): Promise<string> {
  const override = Deno.env.get("BUNDLR_UV_EXECUTABLE");
  if (override !== undefined) return override;

  const executableName = Deno.build.os === "windows" ? "uv.exe" : "uv";
  const bundledUrl = new URL(`../../vendor/uv/${executableName}`, import.meta.url);
  const checksumUrl = new URL(`../../vendor/uv/${executableName}.sha256`, import.meta.url);

  try {
    const [binary, expectedChecksum] = await Promise.all([
      Deno.readFile(bundledUrl),
      Deno.readTextFile(checksumUrl),
    ]);
    await verifyChecksum(binary, expectedChecksum.trim());
    return await installBundledUv(binary, executableName);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return executableName;
    throw error;
  }
}

export async function diagnoseUv(): Promise<string> {
  const executable = await resolveUvExecutable();
  const output = await new Deno.Command(executable, {
    args: ["--version"],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) {
    throw new Error(
      `uv diagnostic failed: ${new TextDecoder().decode(output.stderr).trim()}`,
    );
  }
  const version = new TextDecoder().decode(output.stdout).trim();
  if (!version.startsWith(`uv ${UV_VERSION} `)) {
    throw new Error(`Expected uv ${UV_VERSION}, received ${version || "no version output"}.`);
  }
  return version;
}

async function installBundledUv(binary: Uint8Array, executableName: string): Promise<string> {
  const destinationDirectory = cacheDirectory();
  const destination = `${destinationDirectory}/${UV_VERSION}/${executableName}`;
  try {
    await Deno.stat(destination);
    return destination;
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }

  await Deno.mkdir(`${destinationDirectory}/${UV_VERSION}`, { recursive: true });
  const temporary = `${destination}.${crypto.randomUUID()}.tmp`;
  try {
    await Deno.writeFile(temporary, binary, { createNew: true, mode: 0o755 });
    if (Deno.build.os !== "windows") await Deno.chmod(temporary, 0o755);
    try {
      await Deno.rename(temporary, destination);
    } catch (error) {
      if (!(error instanceof Deno.errors.AlreadyExists)) throw error;
    }
  } finally {
    await Deno.remove(temporary).catch((error) => {
      if (!(error instanceof Deno.errors.NotFound)) throw error;
    });
  }
  return destination;
}

async function verifyChecksum(binary: Uint8Array, expected: string): Promise<void> {
  if (!/^[a-fA-F0-9]{64}$/.test(expected)) {
    throw new Error("The bundled uv checksum is invalid.");
  }
  const input = Uint8Array.from(binary);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  const actual = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
  if (actual !== expected.toLowerCase()) {
    throw new Error("The bundled uv executable failed checksum verification.");
  }
}

function cacheDirectory(): string {
  switch (Deno.build.os) {
    case "windows":
      return `${requiredEnvironment("LOCALAPPDATA")}\\Bundlr\\runtime`;
    case "darwin":
      return `${requiredEnvironment("HOME")}/Library/Caches/bundlr/runtime`;
    default: {
      const xdgCache = Deno.env.get("XDG_CACHE_HOME");
      return `${xdgCache ?? `${requiredEnvironment("HOME")}/.cache`}/bundlr/runtime`;
    }
  }
}

function requiredEnvironment(name: string): string {
  const value = Deno.env.get(name);
  if (value === undefined || value.length === 0) {
    throw new Error(`Required environment variable ${name} is not set.`);
  }
  return value;
}
