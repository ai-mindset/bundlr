import type { PackageRequest } from "../domain/package_request.ts";
import { parsePythonEntryPoint, type PythonEntryPoint } from "./entry_point.ts";
import type { Invocation } from "./invocation.ts";

const INSPECT_SCRIPT = `
import importlib.metadata
import json
import sys

matches = [
    {"group": group, "name": entry.name, "value": entry.value}
    for group in ("console_scripts", "gui_scripts")
    for entry in importlib.metadata.entry_points(group=group)
    if entry.name == sys.argv[1]
]
print(json.dumps(matches, sort_keys=True))
`.trim();

export class EntryPointNotFoundError extends Error {
  override readonly name = "EntryPointNotFoundError";
}

export function buildEntryPointInspection(request: PackageRequest): Invocation {
  const source = request.source.kind === "git"
    ? `git+${request.source.url.href}`
    : request.source.requirement;

  return {
    args: [
      "--no-config",
      "run",
      "--no-project",
      "--python",
      request.python,
      "--with",
      source,
      "python",
      "-c",
      INSPECT_SCRIPT,
      request.command,
    ],
    env: {
      UV_NO_SYSTEM_CONFIG: "1",
      UV_PYTHON_PREFERENCE: "only-managed",
    },
  };
}

export function decodeInspectedEntryPoint(
  output: string,
  command: string,
): PythonEntryPoint {
  let value: unknown;
  try {
    value = JSON.parse(output);
  } catch (error) {
    throw new EntryPointNotFoundError(
      `Could not inspect the "${command}" entry point.`,
      { cause: error },
    );
  }

  if (!Array.isArray(value) || value.length !== 1) {
    throw new EntryPointNotFoundError(
      value instanceof Array && value.length > 1
        ? `More than one "${command}" application entry point was found.`
        : `The package does not provide a "${command}" application entry point.`,
    );
  }

  const match = value[0];
  if (
    typeof match !== "object" ||
    match === null ||
    typeof (match as Record<string, unknown>).value !== "string"
  ) {
    throw new EntryPointNotFoundError(`The "${command}" entry point is invalid.`);
  }

  return parsePythonEntryPoint((match as { value: string }).value);
}
