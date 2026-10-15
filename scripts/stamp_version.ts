import { writeFile } from "node:fs/promises";

const tag = process.env.BUNDLR_RELEASE_TAG;
if (tag === undefined || !/^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/.test(tag)) {
  throw new Error(`Invalid release tag: ${tag}`);
}

await writeFile(
  "src/version.ts",
  `export const BUNDLR_VERSION = ${JSON.stringify(tag.slice(1))};\n`,
);
