export interface Invocation {
  readonly args: readonly string[];
  readonly env: Readonly<Record<string, string>>;
}

export interface ProcessEvents {
  readonly stdout?: (text: string) => unknown;
  readonly stderr?: (text: string) => unknown;
}
export interface ProcessOptions {
  readonly captureStdout?: boolean;
  readonly captureStderr?: boolean;
  readonly events?: ProcessEvents;
  readonly signal?: AbortSignal;
}
export interface ProcessResult {
  readonly success: boolean;
  readonly code: number;
  readonly stdout?: string;
  readonly stderr?: string;
}
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
  const result = await runInvocation(
    executable,
    { args, env: {} },
    { captureStdout: true, captureStderr: true, signal },
  );
  return {
    success: result.success,
    code: result.code,
    stdout: result.stdout!,
    stderr: result.stderr!,
  };
}
export async function runInvocation(
  executable: string,
  invocation: Invocation,
  options: ProcessOptions = {},
): Promise<ProcessResult> {
  options.signal?.throwIfAborted();
  const child = Bun.spawn([executable, ...invocation.args], {
    env: { ...process.env, ...invocation.env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    detached: process.platform !== "win32",
    windowsHide: true,
  });
  const stop = (signal: "SIGTERM" | "SIGKILL") => {
    try {
      if (process.platform === "win32") {
        if (child.exitCode === null) {
          const result = Bun.spawnSync(
            ["taskkill.exe", "/pid", String(child.pid), "/t", "/f"],
            { stdout: "ignore", stderr: "ignore", windowsHide: true },
          );
          if (result.exitCode !== 0) child.kill("SIGKILL");
        }
      } else process.kill(-child.pid, signal);
    } catch (error) {
      if (!(
        error instanceof Error &&
        "code" in error &&
        error.code === "ESRCH"
      ))
        throw error;
    }
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const abort = () => {
    stop("SIGTERM");
    timer = setTimeout(() => stop("SIGKILL"), 1000);
  };
  options.signal?.addEventListener("abort", abort, { once: true });
  if (options.signal?.aborted) abort();
  const stdout: string[] = [],
    stderr: string[] = [];
  let completed = false;
  try {
    const [code] = await Promise.all([
      child.exited,
      consumeText(child.stdout, (text) => {
        if (options.captureStdout) stdout.push(text);
        return options.events?.stdout?.(text);
      }),
      consumeText(child.stderr, (text) => {
        if (options.captureStderr) stderr.push(text);
        return options.events?.stderr?.(text);
      }),
    ]);
    options.signal?.throwIfAborted();
    completed = true;
    return {
      success: code === 0,
      code,
      ...(options.captureStdout ? { stdout: stdout.join("") } : {}),
      ...(options.captureStderr ? { stderr: stderr.join("") } : {}),
    };
  } finally {
    options.signal?.removeEventListener("abort", abort);
    if (timer !== undefined) clearTimeout(timer);
    if (!completed || options.signal?.aborted) {
      stop("SIGKILL");
      await child.exited;
    }
  }
}
async function consumeText(
  stream: ReadableStream<Uint8Array>,
  listener: (text: string) => unknown,
): Promise<void> {
  const reader = stream.getReader(),
    decoder = new TextDecoder();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        const rest = decoder.decode();
        if (rest) await listener(rest);
        return;
      }
      const text = decoder.decode(value, { stream: true });
      if (text) await listener(text);
    }
  } finally {
    reader.releaseLock();
  }
}
