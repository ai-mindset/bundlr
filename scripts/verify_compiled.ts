import assert from "node:assert/strict";
import {
  chmod,
  lstat,
  mkdtemp,
  readFile,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { gzipSync } from "node:zlib";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { executablePath, run } from "../tests/helpers.ts";
import { currentTarget } from "../src/core/target.ts";
import { UV_VERSION } from "../src/uv_version.ts";
import { BUNDLR_VERSION } from "../src/version.ts";
const args = process.argv.slice(2).filter((arg) => arg !== "--");
if (args.length > 1)
  throw new Error("Usage: bun scripts/verify_compiled.ts [binary]");
const binary = resolve(args[0] ?? executablePath());
const base = await mkdtemp(join(tmpdir(), "bundlr-integrity-"));
const cache = join(base, "cache");
const env = Object.fromEntries(
  Object.entries(process.env).filter(
    ([name]) => !["PATH", "BUNDLR_UV_EXECUTABLE"].includes(name.toUpperCase()),
  ),
);
env.PATH = "";
env.BUNDLR_CACHE_DIRECTORY = cache;
const provenance = JSON.parse(
  await readFile("vendor/uv/provenance.json", "utf8"),
);
const cached = join(
  cache,
  UV_VERSION,
  currentTarget(),
  process.platform === "win32" ? "uv.exe" : "uv",
);
const digest = async (path: string) =>
  createHash("sha256")
    .update(await readFile(path))
    .digest("hex");
try {
  assert.match(await run([binary, "--help"], { env, cwd: base }), /--command/);
  assert.equal(
    (await run([binary, "--version"], { env, cwd: base })).trim(),
    BUNDLR_VERSION,
  );
  for (const invalid of [
    ["unpinned"],
    ["black==26.5.1", "--python", "3.13"],
    ["black==26.5.1", "--target", "invalid"],
    ["black==26.5.1", "--name", "../invalid"],
  ]) {
    await run([binary, ...invalid, "--output", join(base, "invalid-output")], {
      env,
      cwd: base,
      success: false,
    });
  }
  assert.deepEqual(await readdir(base), []);
  assert.match(
    await run([binary, "--diagnose"], { env, cwd: base }),
    /Runtime diagnostic passed/,
  );
  assert.equal(await digest(cached), provenance.executableSha256);
  await writeFile(cached, "corrupt cached tool");
  await run([binary, "--diagnose"], { env, cwd: base });
  assert.equal(await digest(cached), provenance.executableSha256);
  if (process.platform !== "win32") {
    await chmod(cached, 0o644);
    await run([binary, "--diagnose"], { env, cwd: base });
    assert.ok((await lstat(cached)).mode & 0o111);
  }
  const invalid = join(base, "unverified-override");
  await writeFile(invalid, "untrusted bytes");
  assert.match(
    await run([binary, "--diagnose"], {
      env: { ...env, BUNDLR_UV_EXECUTABLE: invalid },
      cwd: base,
      success: false,
    }),
    /checksum-pinned/,
  );
  if (process.platform !== "win32") {
    await rm(cached);
    await symlink(invalid, cached);
    await run([binary, "--diagnose"], { env, cwd: base });
    assert.equal((await lstat(cached)).isSymbolicLink(), false);
    assert.equal(await readFile(invalid, "utf8"), "untrusted bytes");
  }
  const contents = await readFile(binary),
    payload = await readFile("vendor/uv/uv.gz");
  const offset = contents.indexOf(payload);
  assert.ok(
    offset >= 0,
    "Cannot locate embedded payload for the tamper check.",
  );
  contents.fill(0, offset, offset + payload.length);
  gzipSync(Buffer.from("untrusted embedded uv")).copy(contents, offset);
  const damaged = join(
    base,
    "damaged-bundlr" + (process.platform === "win32" ? ".exe" : ""),
  );
  await writeFile(damaged, contents, { mode: 0o755 });
  if (process.platform === "darwin")
    await run(["codesign", "--force", "--sign", "-", damaged]);
  assert.match(
    await run([damaged, "--diagnose"], {
      env: { ...env, BUNDLR_CACHE_DIRECTORY: join(base, "fresh-cache") },
      cwd: base,
      success: false,
    }),
    /SHA-256 verification/,
  );
  console.log(
    "Compiled CLI validation, offline integrity, override rejection and cache repair passed: " +
      currentTarget(),
  );
} finally {
  await rm(base, { recursive: true, force: true });
}
