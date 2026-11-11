export type PackageSource =
  | { readonly kind: "pypi"; readonly requirement: string }
  | { readonly kind: "git"; readonly url: URL };

export class InvalidPackageSourceError extends Error {
  override readonly name = "InvalidPackageSourceError";
}

export function parsePackageSource(input: string): PackageSource {
  const value = input.trim();
  if (value.length === 0) {
    throw new InvalidPackageSourceError("Enter a PyPI requirement or Git URL.");
  }

  if (value.startsWith("git+")) {
    return parseGitUrl(value.slice(4));
  }

  if (value.startsWith("https://") || value.startsWith("http://")) {
    return parseGitUrl(value);
  }

  const identifier = "[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?";
  const pinned = new RegExp(
    `^${identifier}(?:\\[${identifier}(?:,${identifier})*\\])?==([^=]+)$`,
  );
  const match = pinned.exec(value);
  const version = match?.[1];
  if (
    version === undefined ||
    !/^v?(?:[0-9]+!)?[0-9]+(?:\.[0-9]+)*(?:[-_.]?(?:alpha|a|beta|b|preview|pre|rc|c)[-_.]?[0-9]*)?(?:-[0-9]+|[-_.]?(?:post|rev|r)[-_.]?[0-9]*)?(?:[-_.]?dev[-_.]?[0-9]*)?(?:\+[a-z0-9]+(?:[-_.][a-z0-9]+)*)?$/i.test(
      version,
    )
  ) {
    throw new InvalidPackageSourceError(
      "Use a pinned PyPI requirement (name[extras]==version) or HTTPS Git URL.",
    );
  }
  return { kind: "pypi", requirement: value };
}

function parseGitUrl(value: string): PackageSource {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new InvalidPackageSourceError(`Invalid Git URL: ${value}`);
  }

  if (url.protocol !== "https:") {
    throw new InvalidPackageSourceError("Git URLs must use HTTPS.");
  }

  return { kind: "git", url };
}
