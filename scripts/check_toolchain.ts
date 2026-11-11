import lock from "../build-lock.json";
export function checkToolchain(): string {
  const result = Bun.spawnSync([process.execPath, "--revision"]);
  const actual = result.stdout.toString().trim();
  if (result.exitCode !== 0 || actual !== lock.bun.revision)
    throw new Error(
      "Expected Bun " +
        lock.bun.revision +
        "; found " +
        actual +
        ". Test and update build-lock.json before changing compilers.",
    );
  return actual;
}
if (import.meta.main) console.log(checkToolchain());
