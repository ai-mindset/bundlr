import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { currentTarget } from "../src/core/target.ts";
export async function hashFile(path: string): Promise<string> {
  return createHash("sha256")
    .update(await readFile(path))
    .digest("hex");
}
export function executablePath(): string {
  return (
    "dist/bundlr-" +
    currentTarget() +
    (process.platform === "win32" ? ".exe" : "")
  );
}
export async function run(
  args: string[],
  options: {
    env?: Record<string, string | undefined>;
    cwd?: string;
    success?: boolean;
    timeout?: number;
  } = {},
): Promise<string> {
  const child = Bun.spawn(args, {
    env: options.env ?? process.env,
    cwd: options.cwd,
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
    timeout: options.timeout ?? 900000,
    windowsHide: true,
  });
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  assert.equal(
    code === 0,
    options.success ?? true,
    JSON.stringify(args) + " exited " + code + "\n" + stdout + stderr,
  );
  return stdout + stderr;
}
export function recipientEnvironment(
  extra: Record<string, string> = {},
): Record<string, string> {
  return {
    PYTHONHOME: "bundlr-must-ignore-builder-python",
    PYTHONPATH: "bundlr-must-ignore-builder-packages",
    PATH:
      process.platform === "win32"
        ? join(process.env.SystemRoot ?? "C:\\Windows", "System32")
        : "/usr/bin:/bin",
    ...(process.platform === "win32"
      ? { SystemRoot: process.env.SystemRoot ?? "C:\\Windows" }
      : {}),
    ...extra,
  };
}
