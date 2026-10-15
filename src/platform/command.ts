export interface CommandOutput {
  readonly success: boolean;
  readonly code: number;
  readonly stdout: string;
  readonly stderr: string;
}

export async function runCommandOutput(
  executable: string,
  args: readonly string[],
  signal?: AbortSignal,
): Promise<CommandOutput> {
  const child = Bun.spawn([executable, ...args], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    signal,
    windowsHide: true,
  });
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { success: code === 0, code, stdout, stderr };
}
