import type { Invocation } from "./invocation.ts";

export interface ProcessEvents {
  readonly stdout?: (text: string) => void;
  readonly stderr?: (text: string) => void;
}

export interface ProcessOptions {
  readonly captureStdout?: boolean;
  readonly events?: ProcessEvents;
  readonly signal?: AbortSignal;
}

export interface ProcessResult {
  readonly success: boolean;
  readonly code: number;
  readonly stdout?: string;
}

export async function runInvocation(
  executable: string,
  invocation: Invocation,
  options: ProcessOptions = {},
): Promise<ProcessResult> {
  const child = new Deno.Command(executable, {
    args: [...invocation.args],
    env: { ...invocation.env },
    stdin: "null",
    stdout: "piped",
    stderr: "piped",
    signal: options.signal,
  }).spawn();

  const stdout: string[] = [];
  const [status] = await Promise.all([
    child.status,
    consumeText(child.stdout, (text) => {
      if (options.captureStdout === true) stdout.push(text);
      options.events?.stdout?.(text);
    }),
    consumeText(child.stderr, options.events?.stderr),
  ]);

  return {
    success: status.success,
    code: status.code,
    ...(options.captureStdout === true ? { stdout: stdout.join("") } : {}),
  };
}

async function consumeText(
  stream: ReadableStream<Uint8Array>,
  listener: ((text: string) => void) | undefined,
): Promise<void> {
  if (listener === undefined) {
    await stream.pipeTo(new WritableStream());
    return;
  }

  const reader = stream.pipeThrough(new TextDecoderStream()).getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return;
      listener(value);
    }
  } finally {
    reader.releaseLock();
  }
}
