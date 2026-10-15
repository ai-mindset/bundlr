import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function isNotFound(error: unknown): boolean {
  return isFileSystemError(error, "ENOENT");
}

export function isAlreadyExists(error: unknown): boolean {
  return isFileSystemError(error, "EEXIST");
}

function isFileSystemError(error: unknown, code: string): boolean {
  return error instanceof Error && "code" in error && error.code === code;
}

export function makeTempDir(options: { prefix: string; dir?: string }): Promise<string> {
  return mkdtemp(join(options.dir ?? tmpdir(), options.prefix));
}

export function readTextFile(path: string | URL): Promise<string> {
  return readFile(path, "utf8");
}

export function writeTextFile(
  path: string,
  contents: string,
  options: { createNew?: boolean; mode?: number } = {},
): Promise<void> {
  return writeFile(path, contents, {
    flag: options.createNew ? "wx" : "w",
    mode: options.mode,
  });
}
