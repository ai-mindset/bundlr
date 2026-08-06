import { join, relative } from "jsr:@std/path@1.1.2";

interface Dependency {
  readonly name: string;
  readonly version: string;
}

export async function writeSupplyChainFiles(root: string, packages: string): Promise<void> {
  const dependencies: Dependency[] = [];
  const licences: string[] = [];
  for await (const entry of Deno.readDir(packages)) {
    if (!entry.isDirectory || !entry.name.endsWith(".dist-info")) continue;
    const directory = join(packages, entry.name);
    const metadata = await Deno.readTextFile(join(directory, "METADATA"));
    dependencies.push({
      name: metadataHeader(metadata, "Name") ?? entry.name.replace(/\.dist-info$/, ""),
      version: metadataHeader(metadata, "Version") ?? "unknown",
    });
    for await (const file of Deno.readDir(directory)) {
      if (!file.isFile || !/^(LICEN[CS]E|COPYING|NOTICE)/i.test(file.name)) continue;
      licences.push(
        `===== ${entry.name}/${file.name} =====\n${await Deno.readTextFile(
          join(directory, file.name),
        )}`,
      );
    }
  }
  dependencies.sort((left, right) => left.name.localeCompare(right.name));
  await Deno.writeTextFile(
    join(root, "bundlr-dependencies.json"),
    JSON.stringify({ formatVersion: 1, dependencies }, null, 2) + "\n",
    { createNew: true },
  );

  const runtimeLicence = join(root, "runtime", "LICENSE.txt");
  try {
    licences.unshift(
      `===== Python runtime/LICENSE.txt =====\n${await Deno.readTextFile(runtimeLicence)}`,
    );
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  await Deno.writeTextFile(
    join(root, "THIRD_PARTY_LICENSES.txt"),
    licences.join("\n\n") + "\n",
    { createNew: true },
  );

  const manifestPath = join(root, "SHA256SUMS");
  const lines: string[] = [];
  for await (const path of filesIn(root)) {
    if (path === manifestPath) continue;
    lines.push(`${await fileSha256(path)}  ${relative(root, path).replaceAll("\\", "/")}`);
  }
  lines.sort();
  await Deno.writeTextFile(manifestPath, lines.join("\n") + "\n", { createNew: true });
}

function metadataHeader(metadata: string, name: string): string | undefined {
  const prefix = `${name.toLowerCase()}:`;
  return metadata.split(/\r?\n/).find((line) => line.toLowerCase().startsWith(prefix))
    ?.slice(prefix.length).trim();
}

async function* filesIn(directory: string): AsyncGenerator<string> {
  for await (const entry of Deno.readDir(directory)) {
    const path = join(directory, entry.name);
    if (entry.isDirectory) yield* filesIn(path);
    else if (entry.isFile) yield path;
  }
}

async function fileSha256(path: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await Deno.readFile(path)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
