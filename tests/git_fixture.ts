import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import lock from "../build-lock.json";
import data from "./git-fixture-data.json";
import { run } from "./helpers.ts";
export async function gitFixture(
  directory: string,
  portable = true,
): Promise<{ source: string; env: Record<string, string | undefined> }> {
  await mkdir(directory, { recursive: true });
  const pins = (text: string) =>
    text
      .replaceAll("24.2", lock.acceptance.packagingVersion)
      .replaceAll("0.4.6", lock.acceptance.coloramaVersion);
  await writeFile(join(directory, "application.py"), pins(data.application), {
    flag: "wx",
  });
  await writeFile(
    join(directory, "backend.py"),
    pins(data.backend).replaceAll("PURELIB", portable ? "true" : "false"),
    { flag: "wx" },
  );
  await writeFile(
    join(directory, "pyproject.toml"),
    '[build-system]\nrequires = []\nbuild-backend = "backend"\nbackend-path = ["."]\n',
    { flag: "wx" },
  );
  await run(["git", "init", "--initial-branch=main", directory]);
  await run(["git", "-C", directory, "add", "."]);
  await run([
    "git",
    "-C",
    directory,
    "-c",
    "user.name=Bundlr acceptance",
    "-c",
    "user.email=acceptance@example.invalid",
    "commit",
    "-m",
    "Pinned acceptance fixture",
  ]);
  const revision = (
    await run(["git", "-C", directory, "rev-parse", "HEAD"])
  ).trim();
  const source = "https://bundlr-acceptance.invalid/application.git";
  return {
    source: source + "@" + revision,
    env: {
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0:
        "url." + pathToFileURL(resolve(directory)).href + ".insteadOf",
      GIT_CONFIG_VALUE_0: source,
      GIT_TERMINAL_PROMPT: "0",
    },
  };
}
