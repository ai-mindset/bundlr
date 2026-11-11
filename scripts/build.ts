import { createHash } from "node:crypto";
import {
  link,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { currentTarget } from "../src/core/target.ts";
import { checkToolchain } from "./check_toolchain.ts";
const target = currentTarget(),
  revision = checkToolchain();
if (process.argv.length > 3)
  throw new Error("Usage: bun scripts/build.ts [new-output-path]");
const output = resolve(
  process.argv[2] ??
    "dist/bundlr-" + target + (process.platform === "win32" ? ".exe" : ""),
);
for (const path of [output, output + ".json", output + ".sha256"]) {
  try {
    await lstat(path);
    throw new Error("Refusing to overwrite " + path);
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT"))
      throw error;
  }
}
const payload = JSON.parse(await readFile("vendor/uv/provenance.json", "utf8"));
if (payload.target !== target)
  throw new Error("Prepare uv for the native build host first.");
await mkdir(dirname(output), { recursive: true });
const stage = await mkdtemp(join(dirname(output), ".bundlr-compile-"));
try {
  const staged = join(
    stage,
    "bundlr" + (process.platform === "win32" ? ".exe" : ""),
  );
  const args = [
    "compile",
    "--trim",
    "--minify",
    "--disallow-code-generation-from-strings=strict",
    "--no-compile-function-source",
    "--no-compile-autoload-dotenv",
    "--no-compile-autoload-bunfig",
    "src/main.ts",
    "--outfile",
    staged,
  ];
  const compiler = Bun.spawn([process.execPath, ...args], {
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await compiler.exited) !== 0) throw new Error("AOT compilation failed.");
  const scratch = join(stage, "empty-workspace");
  await mkdir(scratch);
  for (const option of ["--help", "--diagnose"]) {
    const probe = Bun.spawn([staged, option], {
      cwd: scratch,
      env: {
        ...process.env,
        PATH: "",
        BUNDLR_UV_EXECUTABLE: undefined,
        BUNDLR_CACHE_DIRECTORY: join(stage, "cache"),
      },
      stdout: "inherit",
      stderr: "inherit",
      timeout: 60000,
    });
    if ((await probe.exited) !== 0)
      throw new Error("Compiled executable failed " + option);
  }
  const bytes = await readFile(staged);
  const metadata = {
    target,
    compilerRevision: revision,
    arguments: args.slice(0, -1).concat(output),
    executableBytes: bytes.length,
    executableMiB: bytes.length / 1024 ** 2,
    compressedUvBytes: (await lstat("vendor/uv/uv.gz")).size,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    validation:
      "help and offline diagnostic passed; complete acceptance required before release",
  };
  await writeFile(
    join(stage, "build.json"),
    JSON.stringify(metadata, null, 2) + "\n",
    { flag: "wx" },
  );
  await writeFile(
    join(stage, "checksum"),
    metadata.sha256 + "  " + basename(output) + "\n",
    { flag: "wx" },
  );
  await link(staged, output);
  let recordPublished = false;
  try {
    await link(join(stage, "build.json"), output + ".json");
    recordPublished = true;
    await link(join(stage, "checksum"), output + ".sha256");
  } catch (error) {
    if (recordPublished) await rm(output + ".json");
    await rm(output);
    throw error;
  }
  console.log(JSON.stringify(metadata, null, 2));
} finally {
  await rm(stage, { recursive: true, force: true });
}
