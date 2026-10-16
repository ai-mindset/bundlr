import { test } from "bun:test";
import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import JSZip from "jszip";
import { assertEquals, assertRejects } from "../test/assert.ts";
import { makeTempDir } from "./fs.ts";
import { runCommandOutput } from "./command.ts";
import { ensureUvRelease, type UvFetch, type UvRelease } from "./uv_release.ts";

const windowsTarget = "x86_64-pc-windows-msvc";
const windowsArchive = "uv-x86_64-pc-windows-msvc.zip";

test("anchors cached uv to the pinned archive and repairs it offline", async () => {
  const cache = await makeTempDir({ prefix: "bundlr-uv-test-" });
  const binary = new TextEncoder().encode("verified uv bytes");
  const zip = new JSZip();
  zip.file("uv-x86_64-pc-windows-msvc/uv.exe", binary);
  const archive = await zip.generateAsync({ type: "uint8array" });
  const { release, manifest } = await fixtureRelease(windowsArchive, archive);
  let requests = 0;
  const download: UvFetch = async (input) => {
    requests++;
    return response(String(input).endsWith("/sha256.sum") ? manifest : archive);
  };

  try {
    const versionDirectory = join(cache, release.version);
    await mkdir(versionDirectory, { recursive: true });
    await writeFile(join(versionDirectory, "uv.exe"), "unverified cached executable");
    const executable = await ensureUvRelease(release, windowsTarget, cache, { fetch: download });
    assertEquals(await readFile(executable), binary);
    assertEquals(requests, 2);

    const offline: UvFetch = async () => {
      throw new Error("unexpected network request");
    };
    assertEquals(
      await ensureUvRelease(release, windowsTarget, cache, { fetch: offline }),
      executable,
    );

    await writeFile(executable, "corrupt");
    await ensureUvRelease(release, windowsTarget, cache, { fetch: offline });
    assertEquals(await readFile(executable), binary);
    assertEquals(requests, 2);

    await writeFile(join(versionDirectory, windowsArchive), "corrupt archive");
    await ensureUvRelease(release, windowsTarget, cache, { fetch: download });
    assertEquals(await readFile(executable), binary);
    assertEquals(requests, 4);
  } finally {
    await rm(cache, { recursive: true });
  }
});

test("rejects an altered uv checksum manifest before downloading the archive", async () => {
  const cache = await makeTempDir({ prefix: "bundlr-uv-test-" });
  const archive = new TextEncoder().encode("archive");
  const { release, manifest } = await fixtureRelease(windowsArchive, archive);
  let requests = 0;
  const download: UvFetch = async () => {
    requests++;
    return new Response(`${new TextDecoder().decode(manifest)}tampered`);
  };

  try {
    await assertRejects(
      () => ensureUvRelease(release, windowsTarget, cache, { fetch: download }),
      Error,
      "uv checksum manifest failed SHA-256 verification",
    );
    assertEquals(requests, 1);
    await assertRejects(() => stat(join(cache, release.version, "uv.exe")), Error);
  } finally {
    await rm(cache, { recursive: true });
  }
});

test("rejects an altered uv archive before installing an executable", async () => {
  const cache = await makeTempDir({ prefix: "bundlr-uv-test-" });
  const archive = new TextEncoder().encode("original archive");
  const { release, manifest } = await fixtureRelease(windowsArchive, archive);
  const download: UvFetch = async (input) =>
    response(
      String(input).endsWith("/sha256.sum") ? manifest : new TextEncoder().encode("altered"),
    );

  try {
    await assertRejects(
      () => ensureUvRelease(release, windowsTarget, cache, { fetch: download }),
      Error,
      `${windowsArchive} failed SHA-256 verification`,
    );
    await assertRejects(() => stat(join(cache, release.version, "uv.exe")), Error);
  } finally {
    await rm(cache, { recursive: true });
  }
});

test("preserves cancellation during a uv download", async () => {
  const cache = await makeTempDir({ prefix: "bundlr-uv-test-" });
  const archive = new TextEncoder().encode("archive");
  const { release } = await fixtureRelease(windowsArchive, archive);
  const controller = new AbortController();
  const download: UvFetch = async () => {
    controller.abort(new Error("Packaging cancelled"));
    throw controller.signal.reason;
  };

  try {
    await assertRejects(
      () =>
        ensureUvRelease(release, windowsTarget, cache, {
          fetch: download,
          signal: controller.signal,
        }),
      Error,
      "Packaging cancelled",
    );
  } finally {
    await rm(cache, { recursive: true });
  }
});

if (process.platform !== "win32") {
  test("extracts a verified Unix uv archive", async () => {
    const cache = await makeTempDir({ prefix: "bundlr-uv-test-" });
    const source = await makeTempDir({ prefix: "bundlr-uv-source-test-" });
    const target = "x86_64-unknown-linux-gnu";
    const artifact = `uv-${target}.tar.gz`;
    const binary = new TextEncoder().encode("unix uv bytes");
    try {
      await writeFile(join(source, "uv"), binary);
      const archivePath = join(source, artifact);
      const result = await runCommandOutput("tar", ["-czf", archivePath, "-C", source, "uv"]);
      assertEquals(result.success, true);
      const archive = await readFile(archivePath);
      const { release, manifest } = await fixtureRelease(artifact, archive);
      const download: UvFetch = async (input) =>
        response(String(input).endsWith("/sha256.sum") ? manifest : archive);
      const executable = await ensureUvRelease(release, target, cache, { fetch: download });
      assertEquals(await readFile(executable), binary);
      assertEquals((await stat(executable)).mode & 0o111, 0o111);
    } finally {
      await rm(cache, { recursive: true });
      await rm(source, { recursive: true });
    }
  });
}

async function fixtureRelease(
  artifact: string,
  archive: Uint8Array,
): Promise<{ release: UvRelease; manifest: Uint8Array }> {
  const manifest = new TextEncoder().encode(`${await sha256(archive)}  ${artifact}\n`);
  return {
    release: {
      version: "0.11.16",
      baseUrl: "https://example.invalid/uv/0.11.16",
      checksumManifestSha256: await sha256(manifest),
    },
    manifest,
  };
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function response(bytes: Uint8Array): Response {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return new Response(copy.buffer);
}
