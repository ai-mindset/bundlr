import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join, resolve, sep } from "node:path";
import type { TargetPlatform } from "../src/domain/package_request.ts";
import JSZip from "jszip";
import { dirname } from "node:path";
import lock from "../build-lock.json";
import { hashFile, recipientEnvironment, run } from "./helpers.ts";
export function artifactName(name: string, target: TargetPlatform): string {
  return name + "-" + target + (target.startsWith("macos-") ? ".app" : "");
}
export function launcher(
  directory: string,
  name: string,
  target: TargetPlatform,
): string {
  return target.startsWith("macos-")
    ? join(directory, "Contents/MacOS", name)
    : join(directory, name + (target === "windows-x86_64" ? ".exe" : ""));
}
export async function verifyRecipient(
  archive: string,
  extract: string,
  name: string,
  target: TargetPlatform,
  source?: string,
  execute = true,
): Promise<string> {
  const checksum = (await readFile(archive + ".sha256", "utf8")).trim();
  assert.equal(checksum, (await hashFile(archive)) + "  " + basename(archive));
  await mkdir(extract, { recursive: true });
  if (target === "windows-x86_64" && process.platform !== "win32") {
    const zip = await JSZip.loadAsync(await readFile(archive));
    for (const entry of Object.values(zip.files)) {
      const path = resolve(extract, entry.name);
      assert.ok(
        path.startsWith(resolve(extract) + sep),
        "Unsafe ZIP entry: " + entry.name,
      );
      if (entry.dir) {
        await mkdir(path, { recursive: true });
        continue;
      }
      const mode =
        typeof entry.unixPermissions === "number" ? entry.unixPermissions : 0;
      assert.notEqual(mode & 0o170000, 0o120000, "Unexpected ZIP symlink");
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, await entry.async("uint8array"), {
        flag: "wx",
        mode: mode & 0o777 || 0o644,
      });
    }
  } else await run(["tar", "-xf", archive, "-C", extract]);
  const artifact = join(extract, artifactName(name, target));
  const resources = target.startsWith("macos-")
    ? join(artifact, "Contents/Resources")
    : artifact;
  const manifest = JSON.parse(
    await readFile(join(resources, "bundlr-manifest.json"), "utf8"),
  );
  assert.equal(manifest.target, target);
  if (source !== undefined) assert.equal(manifest.source, source);
  const sums = await readFile(join(resources, "SHA256SUMS"), "utf8");
  assert.ok(sums.length > 0);
  for (const line of sums.trim().split(/\r?\n/)) {
    const match = /^([a-f0-9]{64})  (.+)$/.exec(line);
    assert.ok(match, line);
    const file = resolve(resources, match[2]!);
    assert.ok(
      file.startsWith(resolve(resources) + sep),
      "Invalid hash inventory path: " + file,
    );
    assert.equal(await hashFile(file), match[1]);
  }
  const licences = await readFile(
    join(resources, "THIRD_PARTY_LICENSES.txt"),
    "utf8",
  );
  assert.ok(licences.length > 0);
  if (source !== undefined) {
    const inventory = JSON.parse(
      await readFile(join(resources, "bundlr-dependencies.json"), "utf8"),
    );
    const versions = new Map(
      inventory.dependencies.map((item: { name: string; version: string }) => [
        item.name.toLowerCase(),
        item.version,
      ]),
    );
    assert.equal(versions.get("packaging"), lock.acceptance.packagingVersion);
    assert.equal(versions.has("colorama"), target === "windows-x86_64");
  }
  if (execute) {
    const arguments_ =
      name === "Black" || name === "BlackBrowser"
        ? ["--version"]
        : ["literal spaces; $(safe)", 'quoted "value"'];
    const output = await run(
      [launcher(artifact, name, target), ...arguments_],
      { env: recipientEnvironment(), timeout: 60000 },
    );
    assert.ok(
      output.includes(
        name.startsWith("Black")
          ? "black, " + lock.acceptance.blackVersion
          : "Bundlr Git acceptance:",
      ),
      output,
    );
  }
  return artifact;
}
