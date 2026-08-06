export interface Invocation {
  readonly args: readonly string[];
  readonly env: Readonly<Record<string, string>>;
}
