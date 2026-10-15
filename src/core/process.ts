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
  const child = Bun.spawn([executable, ...invocation.args], {
    env: { ...process.env, ...invocation.env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    signal: options.signal,
    windowsHide: true,
  });

  const stdout: string[] = [];
  const [code] = await Promise.all([
    child.exited,
    consumeText(child.stdout, (text) => {
      if (options.captureStdout === true) stdout.push(text);
      options.events?.stdout?.(text);
    }),
    consumeText(child.stderr, options.events?.stderr),
  ]);

  return {
    success: code === 0,
    code,
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

  const reader = stream.getReader();
  const decoder = new TextDecoder();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        const finalText = decoder.decode();
        if (finalText) listener(finalText);
        return;
      }
      const text = decoder.decode(value, { stream: true });
      if (text) listener(text);
    }
  } finally {
    reader.releaseLock();
  }
}
