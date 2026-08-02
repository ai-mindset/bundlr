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
