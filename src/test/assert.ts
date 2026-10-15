import { deepStrictEqual, match, rejects, throws } from "node:assert/strict";

export function assertEquals(actual: unknown, expected: unknown): void {
  if (actual instanceof Uint8Array && expected instanceof Uint8Array) {
    deepStrictEqual([...actual], [...expected]);
    return;
  }
  deepStrictEqual(actual, expected);
}

export function assertMatch(actual: string, expected: RegExp): void {
  match(actual, expected);
}

export function assertStringIncludes(actual: string, expected: string): void {
  if (!actual.includes(expected)) {
    throw new Error(`Expected ${JSON.stringify(actual)} to include ${JSON.stringify(expected)}.`);
  }
}

export function assertThrows(
  action: () => unknown,
  errorType: new (...args: never[]) => Error,
  message?: string,
): void {
  throws(action, (error: unknown) => matches(error, errorType, message));
}

export function assertRejects(
  action: () => Promise<unknown>,
  errorType: new (...args: never[]) => Error,
  message?: string,
): Promise<void> {
  return rejects(action, (error: unknown) => matches(error, errorType, message));
}

function matches(
  error: unknown,
  errorType: new (...args: never[]) => Error,
  message?: string,
): boolean {
  return error instanceof errorType && (message === undefined || error.message.includes(message));
}
