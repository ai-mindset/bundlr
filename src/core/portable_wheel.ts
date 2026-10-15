import { readTextFile } from "../platform/fs.ts";
import { join } from "node:path";

export class NonPortableGitPackageError extends Error {
  override readonly name = "NonPortableGitPackageError";
}

export async function requirePortableGitWheel(metadataDirectory: string): Promise<void> {
  const wheel = await readTextFile(join(metadataDirectory, "WHEEL"));
  const pure = /^Root-Is-Purelib:\s*true\s*$/im.test(wheel);
  const tags = [...wheel.matchAll(/^Tag:\s*(\S+)\s*$/gim)].map((match) => match[1]!);
  if (!pure || tags.length === 0 || tags.some((tag) => !tag.endsWith("-none-any"))) {
    throw new NonPortableGitPackageError(
      "The Git project produced a platform-specific wheel on the host. " +
        "Cross-target Git builds currently require a pure-Python root project.",
    );
  }
}
