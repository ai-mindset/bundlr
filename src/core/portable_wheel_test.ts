import { assertRejects } from "jsr:@std/assert@1.0.19";
import { NonPortableGitPackageError, requirePortableGitWheel } from "./portable_wheel.ts";

Deno.test("accepts a pure platform-independent Git wheel", async () => {
  await withWheel("Root-Is-Purelib: true\nTag: py3-none-any\n", requirePortableGitWheel);
});

Deno.test("rejects a host-native Git wheel", async () => {
  await assertRejects(
    () =>
      withWheel(
        "Root-Is-Purelib: false\nTag: cp312-cp312-manylinux_2_28_x86_64\n",
        requirePortableGitWheel,
      ),
    NonPortableGitPackageError,
    "platform-specific wheel",
  );
});

async function withWheel(
  contents: string,
  operation: (directory: string) => Promise<void>,
): Promise<void> {
  const directory = await Deno.makeTempDir({ prefix: "bundlr-wheel-test-" });
  try {
    await Deno.writeTextFile(`${directory}/WHEEL`, contents);
    await operation(directory);
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
}
