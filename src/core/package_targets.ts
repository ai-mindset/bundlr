import type { PackageRequest } from "../domain/package_request.ts";
import { type ClientArchive, createClientArchive } from "./client_archive.ts";
import { packageApplication, type PackageResult } from "./package_application.ts";
import type { ProcessEvents } from "./process.ts";

export interface PackagedTarget extends PackageResult, ClientArchive {}

export async function packageTargets(
  request: PackageRequest,
  events: ProcessEvents = {},
  signal?: AbortSignal,
): Promise<PackagedTarget[]> {
  const results: PackagedTarget[] = [];
  for (const target of request.targets) {
    events.stderr?.(`\nPackaging ${target}...\n`);
    const result = await packageApplication({ ...request, targets: [target] }, events, signal);
    const archive = await createClientArchive(result);
    results.push({ ...result, ...archive });
  }
  return results;
}
