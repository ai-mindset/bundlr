import { readFile, opendir } from "node:fs/promises";
import { isNotFound, readTextFile, writeTextFile } from "../platform/fs.ts";
import { join, relative } from "node:path";

interface Dependency {
  readonly name: string;
  readonly version: string;
}

export async function writeSupplyChainFiles(root: string, packages: string): Promise<void> {
  const dependencies: Dependency[] = [];
  const licences: string[] = [];
  for await (const entry of await opendir(packages)) {
    if (!entry.isDirectory() || !entry.name.endsWith(".dist-info")) continue;
    const directory = join(packages, entry.name);
    const metadata = await readTextFile(join(directory, "METADATA"));
    dependencies.push({
      name: metadataHeader(metadata, "Name") ?? entry.name.replace(/\.dist-info$/, ""),
      version: metadataHeader(metadata, "Version") ?? "unknown",
    });
    for await (const file of await opendir(directory)) {
      if (!file.isFile() || !/^(LICEN[CS]E|COPYING|NOTICE)/i.test(file.name)) continue;
      licences.push(
        `===== ${entry.name}/${file.name} =====\n${await readTextFile(join(directory, file.name))}`,
      );
    }
  }
  dependencies.sort((left, right) => left.name.localeCompare(right.name));
  await writeTextFile(
    join(root, "bundlr-dependencies.json"),
    JSON.stringify({ formatVersion: 1, dependencies }, null, 2) + "\n",
    { createNew: true },
  );

  const runtimeLicence = join(root, "runtime", "LICENSE.txt");
  try {
    licences.unshift(
      `===== Python runtime/LICENSE.txt =====\n${await readTextFile(runtimeLicence)}`,
    );
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }
  await writeTextFile(join(root, "THIRD_PARTY_LICENSES.txt"), licences.join("\n\n") + "\n", {
    createNew: true,
  });

  const manifestPath = join(root, "SHA256SUMS");
  const lines: string[] = [];
  for await (const path of filesIn(root)) {
    if (path === manifestPath) continue;
    lines.push(`${await fileSha256(path)}  ${relative(root, path).replaceAll("\\", "/")}`);
  }
  lines.sort();
  await writeTextFile(manifestPath, lines.join("\n") + "\n", { createNew: true });
}

function metadataHeader(metadata: string, name: string): string | undefined {
  const prefix = `${name.toLowerCase()}:`;
  return metadata
    .split(/\r?\n/)
    .find((line) => line.toLowerCase().startsWith(prefix))
    ?.slice(prefix.length)
    .trim();
}

async function* filesIn(directory: string): AsyncGenerator<string> {
  for await (const entry of await opendir(directory)) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* filesIn(path);
    else if (entry.isFile()) yield path;
  }
}

async function fileSha256(path: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await readFile(path)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
