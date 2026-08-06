import { join } from "jsr:@std/path@1.1.2";
import type { ApplicationKind } from "../domain/package_request.ts";
import { parsePythonEntryPoint, type PythonEntryPoint } from "./entry_point.ts";

export class EntryPointNotFoundError extends Error {
  override readonly name = "EntryPointNotFoundError";
}

export interface InstalledEntryPoint {
  readonly command: string;
  readonly applicationKind: Exclude<ApplicationKind, "auto">;
  readonly value: PythonEntryPoint;
  readonly metadataDirectory: string;
}

interface ApplicationEntry {
  readonly name: string;
  readonly value: string;
  readonly applicationKind: Exclude<ApplicationKind, "auto">;
}

export async function findInstalledEntryPoint(
  packagesDirectory: string,
  command: string,
): Promise<InstalledEntryPoint> {
  const matches: Array<ApplicationEntry & { metadataDirectory: string }> = [];
  for await (const entry of Deno.readDir(packagesDirectory)) {
    if (!entry.isDirectory || !entry.name.endsWith(".dist-info")) continue;
    const metadataDirectory = join(packagesDirectory, entry.name);
    const metadataPath = join(metadataDirectory, "entry_points.txt");
    let metadata: string;
    try {
      metadata = await Deno.readTextFile(metadataPath);
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) continue;
      throw error;
    }
    matches.push(
      ...findApplicationEntries(metadata, command).map((entry) => ({
        ...entry,
        metadataDirectory,
      })),
    );
  }

  if (matches.length !== 1) {
    throw new EntryPointNotFoundError(
      matches.length > 1
        ? command.length === 0
          ? `More than one application entry point was found: ${
            matches.map((match) => match.name).join(", ")
          }. Select one with --command.`
          : `More than one "${command}" application entry point was found.`
        : command.length === 0
        ? "The package does not provide an application entry point."
        : `The package does not provide a "${command}" application entry point.`,
    );
  }
  return {
    command: matches[0]!.name,
    applicationKind: matches[0]!.applicationKind,
    value: parsePythonEntryPoint(matches[0]!.value),
    metadataDirectory: matches[0]!.metadataDirectory,
  };
}

export function findApplicationEntries(metadata: string, command: string): ApplicationEntry[] {
  const matches: ApplicationEntry[] = [];
  let section = "";
  for (const line of metadata.split(/\r?\n/)) {
    const trimmed = line.trim();
    const sectionMatch = /^\[([^\]]+)\]$/.exec(trimmed);
    if (sectionMatch !== null) {
      section = sectionMatch[1]!;
      continue;
    }
    if (section !== "console_scripts" && section !== "gui_scripts") continue;
    const assignment = /^([^=]+?)\s*=\s*(.+)$/.exec(trimmed);
    const name = assignment?.[1]?.trim();
    if (name !== undefined && (command.length === 0 || name === command)) {
      matches.push({
        name,
        value: assignment![2]!.trim(),
        applicationKind: section === "gui_scripts" ? "windowed" : "console",
      });
    }
  }
  return matches;
}
