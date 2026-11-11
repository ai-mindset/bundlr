import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { ensureUvRelease, hostUvTarget } from "../src/platform/uv_release.ts";
import { UV_CHECKSUM_MANIFEST_SHA256, UV_VERSION } from "../src/uv_version.ts";
import { currentTarget } from "../src/core/target.ts";
const root = "vendor/uv";
const args = process.argv.slice(2);
if (args.length > 1 || args.some((arg) => arg !== "--prepared"))
  throw new Error("Usage: bun scripts/prepare_uv.ts [--prepared]");
let executable: string;
if (args[0] === "--prepared") {
  const old = JSON.parse(await readFile(root + "/provenance.json", "utf8"));
  if (
    old.version !== UV_VERSION ||
    old.target !== currentTarget() ||
    old.manifestSha256 !== UV_CHECKSUM_MANIFEST_SHA256
  )
    throw new Error(
      "Prepared uv provenance does not match the pinned host release.",
    );
  executable = root + (process.platform === "win32" ? "/uv.exe" : "/uv");
  if (
    createHash("sha256")
      .update(await readFile(executable))
      .digest("hex") !== old.executableSha256
  )
    throw new Error("Prepared uv failed SHA-256 verification.");
} else {
  executable = await ensureUvRelease(
    {
      version: UV_VERSION,
      baseUrl:
        "https://github.com/astral-sh/uv/releases/download/" + UV_VERSION,
      checksumManifestSha256: UV_CHECKSUM_MANIFEST_SHA256,
    },
    hostUvTarget(),
    ".build/verified-uv",
  );
}
const bytes = await readFile(executable),
  compressed = gzipSync(bytes, { level: 9 });
await mkdir(root, { recursive: true });
await writeFile(root + "/uv.gz", compressed);
await writeFile(
  root + "/provenance.json",
  JSON.stringify(
    {
      version: UV_VERSION,
      target: currentTarget(),
      executableSha256: createHash("sha256").update(bytes).digest("hex"),
      manifestSha256: UV_CHECKSUM_MANIFEST_SHA256,
    },
    null,
    2,
  ) + "\n",
);
console.log(
  JSON.stringify({
    version: UV_VERSION,
    target: currentTarget(),
    executableBytes: bytes.length,
    compressedBytes: compressed.length,
  }),
);
