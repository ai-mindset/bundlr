import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import lock from "../build-lock.json";
import { currentTarget } from "../src/core/target.ts";
import { type TargetPlatform } from "../src/domain/package_request.ts";
import {
  executablePath,
  hashFile,
  recipientEnvironment,
  run,
} from "../tests/helpers.ts";
import { gitFixture } from "../tests/git_fixture.ts";
import { launcher, verifyRecipient } from "../tests/recipient.ts";
const args = process.argv.slice(2).filter((arg) => arg !== "--");
const all = args.includes("--all-targets");
const positional = args.filter((arg) => arg !== "--all-targets");
if (positional.length > 2 || positional.some((arg) => arg.startsWith("--")))
  throw new Error(
    "Usage: bun scripts/acceptance.ts [binary] [new-output-directory] [--all-targets]",
  );
const binary = resolve(positional[0] ?? executablePath());
const keep = positional[1] !== undefined;
const base = keep
  ? resolve(positional[1]!)
  : await mkdtemp(join(tmpdir(), "bundlr-acceptance-"));
if (keep) await mkdir(base);
const env = {
  ...process.env,
  BUNDLR_CACHE_DIRECTORY: join(base, "tool-cache"),
  BUNDLR_PYTHON_CACHE_DIRECTORY:
    process.env.BUNDLR_PYTHON_CACHE_DIRECTORY ?? join(base, "python-cache"),
};
try {
  await run([binary, "--diagnose"], { env });
  const fixture = await gitFixture(join(base, "portable"));
  const targets: TargetPlatform[] = all
    ? ["linux-x86_64", "windows-x86_64", "macos-arm64", "macos-x86_64"]
    : [currentTarget()];
  for (const target of targets) {
    for (const spec of [
      {
        name: "Black",
        command: "black",
        source: "black==" + lock.acceptance.blackVersion,
        env,
      },
      {
        name: "GitDemo",
        command: "git-demo",
        source: fixture.source,
        env: { ...env, ...fixture.env },
      },
    ]) {
      const output = join(base, "applications");
      console.log("Packaging acceptance: " + spec.name + " for " + target);
      await run(
        [
          binary,
          "--name",
          spec.name,
          "--command",
          spec.command,
          "--target",
          target,
          "--output",
          output,
          spec.source,
        ],
        { env: spec.env },
      );
      const archive = join(
        output,
        spec.name +
          "-" +
          target +
          (target === "windows-x86_64" ? ".zip" : ".tar.gz"),
      );
      await verifyRecipient(
        archive,
        join(base, "extracted-" + spec.name + "-" + target),
        spec.name,
        target,
        spec.name === "GitDemo" ? fixture.source : undefined,
        target === currentTarget(),
      );
      const checksum = await hashFile(archive);
      await run(
        [
          binary,
          "--name",
          spec.name,
          "--command",
          spec.command,
          "--target",
          target,
          "--output",
          output,
          spec.source,
        ],
        { env: spec.env, success: false },
      );
      assert.equal(await hashFile(archive), checksum);
      assert.equal(
        (await readdir(output)).some((name) => name.startsWith(".bundlr-")),
        false,
      );
    }
  }
  const rejected = await gitFixture(join(base, "nonportable"), false);
  const rejectOutput = join(base, "rejected");
  const rejection = await run(
    [
      binary,
      "--name",
      "Rejected",
      "--command",
      "git-demo",
      "--output",
      rejectOutput,
      rejected.source,
    ],
    { env: { ...env, ...rejected.env }, success: false },
  );
  assert.match(rejection, /pure|portable|platform-specific/i);
  assert.deepEqual(await readdir(rejectOutput), []);
  const ambiguous = join(base, "ambiguous");
  const ambiguity = await run(
    [binary, "--output", ambiguous, "black==" + lock.acceptance.blackVersion],
    { env, success: false },
  );
  assert.match(ambiguity, /--command/);
  assert.deepEqual(await readdir(ambiguous), []);
  if (currentTarget() === "windows-x86_64") {
    const out = join(base, "windowed");
    await run(
      [
        binary,
        "--name",
        "GitWindow",
        "--command",
        "git-window",
        "--kind",
        "windowed",
        "--output",
        out,
        fixture.source,
      ],
      { env: { ...env, ...fixture.env } },
    );
    const extracted = await verifyRecipient(
      join(out, "GitWindow-windows-x86_64.zip"),
      join(base, "extracted-gui"),
      "GitWindow",
      "windows-x86_64",
      fixture.source,
      false,
    );
    const marker = join(base, "gui-success.txt");
    await run([launcher(extracted, "GitWindow", "windows-x86_64")], {
      env: recipientEnvironment({ BUNDLR_GUI_MARKER: marker }),
      timeout: 60000,
    });
    assert.equal(await readFile(marker, "utf8"), "tkinter event loop passed");
  }
  console.log(
    "Production builder and recipient acceptance passed: " + currentTarget(),
  );
} finally {
  if (!keep) await rm(base, { recursive: true, force: true });
}
