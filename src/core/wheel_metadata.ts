import { join } from "jsr:@std/path@1.1.2";

export async function readWheelRequirements(metadataDirectory: string): Promise<string[]> {
  return parseWheelRequirements(await Deno.readTextFile(join(metadataDirectory, "METADATA")));
}

export function parseWheelRequirements(metadata: string): string[] {
  const headers: string[] = [];
  for (const line of metadata.split(/\r?\n/)) {
    if (/^[ \t]/.test(line) && headers.length > 0) {
      headers[headers.length - 1] += line.trimStart();
    } else if (line.length === 0) {
      break;
    } else {
      headers.push(line);
    }
  }
  return headers
    .filter((line) => line.toLowerCase().startsWith("requires-dist:"))
    .map((line) => line.slice(line.indexOf(":") + 1).trim())
    .filter(Boolean);
}
