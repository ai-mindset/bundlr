import type { TargetPlatform } from "../domain/package_request.ts";

export class UnsupportedTargetError extends Error {
  override readonly name = "UnsupportedTargetError";
}

export function currentTarget(
  os: NodeJS.Platform = process.platform,
  arch: string = process.arch,
): TargetPlatform {
  if (os === "linux" && arch === "x64") return "linux-x86_64";
  if (os === "darwin" && arch === "arm64") return "macos-arm64";
  if (os === "darwin" && arch === "x64") return "macos-x86_64";
  if (os === "win32" && arch === "x64") return "windows-x86_64";

  throw new UnsupportedTargetError(`Bundlr does not support packaging on ${os}-${arch}.`);
}
