export interface PythonEntryPoint {
  readonly module: string;
  readonly attributes: readonly string[];
}

export class InvalidEntryPointError extends Error {
  override readonly name = "InvalidEntryPointError";
}

export function parsePythonEntryPoint(value: string): PythonEntryPoint {
  const withoutExtras = value.replace(/\s+\[[^\]]+\]\s*$/, "").trim();
  const separator = withoutExtras.indexOf(":");
  if (separator < 1 || separator === withoutExtras.length - 1) {
    throw new InvalidEntryPointError(`Unsupported Python entry point: ${value}`);
  }

  const module = withoutExtras.slice(0, separator);
  const attributes = withoutExtras.slice(separator + 1).split(".");
  if (!isDottedIdentifier(module) || !attributes.every(isIdentifier)) {
    throw new InvalidEntryPointError(`Unsupported Python entry point: ${value}`);
  }

  return { module, attributes };
}

export function createPythonLauncher(entryPoint: PythonEntryPoint): string {
  const access = entryPoint.attributes.map((attribute) => `.${attribute}`).join("");
  return [
    `import ${entryPoint.module} as _bundlr_module`,
    "",
    'if __name__ == "__main__":',
    `    raise SystemExit(_bundlr_module${access}())`,
    "",
  ].join("\n");
}

function isDottedIdentifier(value: string): boolean {
  return value.split(".").every(isIdentifier);
}

function isIdentifier(value: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
}
