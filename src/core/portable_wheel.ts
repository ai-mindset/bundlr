import { join } from "jsr:@std/path@1.1.2";

export class NonPortableGitPackageError extends Error {
  override readonly name = "NonPortableGitPackageError";
}

export async function requirePortableGitWheel(metadataDirectory: string): Promise<void> {
  const wheel = await Deno.readTextFile(join(metadataDirectory, "WHEEL"));
  const pure = /^Root-Is-Purelib:\s*true\s*$/im.test(wheel);
  const tags = [...wheel.matchAll(/^Tag:\s*(\S+)\s*$/gim)].map((match) => match[1]!);
  if (!pure || tags.length === 0 || tags.some((tag) => !tag.endsWith("-none-any"))) {
    throw new NonPortableGitPackageError(
      "The Git project produced a platform-specific wheel on the host. " +
        "Cross-target Git builds currently require a pure-Python root project.",
    );
  }
}
