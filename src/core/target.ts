import type { TargetPlatform } from "../domain/package_request.ts";

export class UnsupportedTargetError extends Error {
  override readonly name = "UnsupportedTargetError";
}

export function currentTarget(
  os: typeof Deno.build.os = Deno.build.os,
  arch: typeof Deno.build.arch = Deno.build.arch,
): TargetPlatform {
  if (os === "linux" && arch === "x86_64") return "linux-x86_64";
  if (os === "darwin" && arch === "aarch64") return "macos-arm64";
  if (os === "darwin" && arch === "x86_64") return "macos-x86_64";
  if (os === "windows" && arch === "x86_64") return "windows-x86_64";

  throw new UnsupportedTargetError(
    `Bundlr does not support packaging on ${os}-${arch}.`,
  );
}

export function requireNativeTarget(
  targets: readonly TargetPlatform[],
  nativeTarget: TargetPlatform = currentTarget(),
): TargetPlatform {
  if (targets.length !== 1 || targets[0] !== nativeTarget) {
    throw new UnsupportedTargetError(
      `This worker can build only ${nativeTarget}; requested: ${targets.join(", ")}.`,
    );
  }
  return nativeTarget;
}
