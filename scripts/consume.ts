import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { currentTarget } from "../src/core/target.ts";
import { verifyRecipient } from "../tests/recipient.ts";
const directory = process.argv[2];
if (!directory || process.argv.length !== 3)
  throw new Error(
    "Usage: bun scripts/consume.ts <cross-built-archive-directory>",
  );
const target = currentTarget();
const base = await mkdtemp(join(tmpdir(), "bundlr-cross-recipient-"));
try {
  for (const name of ["Black", "GitDemo"]) {
    const extension = target === "windows-x86_64" ? ".zip" : ".tar.gz";
    await verifyRecipient(
      join(resolve(directory), name + "-" + target + extension),
      join(base, name),
      name,
      target,
    );
  }
  console.log(
    "Linux cross-built archives launched without builder tools: " + target,
  );
} finally {
  await rm(base, { recursive: true, force: true });
}
