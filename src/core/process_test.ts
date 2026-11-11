import { test } from "bun:test";

import { assertEquals } from "../test/assert.ts";
import { runInvocation } from "./process.ts";

test("captures and streams stdout while streaming stderr", async () => {
  let streamedStdout = "";
  let streamedStderr = "";
  const result = await runInvocation(
    process.execPath,
    {
      args: [
        "-e",
        'console.log(process.env["BUNDLR_PROCESS_TEST"]); console.error("problem")',
      ],
      env: { BUNDLR_PROCESS_TEST: "ready" },
    },
    {
      captureStdout: true,
      events: {
        stdout: (text) => (streamedStdout += text),
        stderr: (text) => (streamedStderr += text),
      },
    },
  );

  assertEquals(result, { success: true, code: 0, stdout: "ready\n" });
  assertEquals(streamedStdout, "ready\n");
  assertEquals(streamedStderr, "problem\n");
});

test("returns a non-zero child exit code", async () => {
  const result = await runInvocation(process.execPath, {
    args: ["-e", "process.exit(7)"],
    env: {},
  });

  assertEquals(result, { success: false, code: 7 });
});

test("pre-cancelled invocations never spawn", async () => {
  const controller = new AbortController();
  controller.abort(new Error("cancelled before spawn"));
  const { assertRejects } = await import("../test/assert.ts");
  await assertRejects(
    () =>
      runInvocation(
        "missing-executable",
        { args: [], env: {} },
        { signal: controller.signal },
      ),
    Error,
    "cancelled before spawn",
  );
});

test("asynchronous output is flushed before the invocation completes", async () => {
  let release!: () => void, received!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const ready = new Promise<void>((resolve) => {
    received = resolve;
  });
  let completed = false;
  const work = runInvocation(
    process.execPath,
    { args: ["-e", 'console.log("ready")'], env: {} },
    {
      events: {
        async stdout() {
          received();
          await gate;
        },
      },
    },
  ).then((result) => {
    completed = true;
    return result;
  });
  try {
    await ready;
    assertEquals(completed, false);
  } finally {
    release();
    assertEquals((await work).success, true);
  }
});

test("cancellation stops the running child and its descendant", async () => {
  const controller = new AbortController();
  let pid = 0,
    text = "";
  const { assertRejects } = await import("../test/assert.ts");
  const source =
    'const child=Bun.spawn([process.execPath,"-e","setInterval(()=>{},1000)"],{stdout:"ignore",stderr:"ignore",stdin:"ignore"});console.log(child.pid);setInterval(()=>{},1000)';
  try {
    await assertRejects(
      () =>
        runInvocation(
          process.execPath,
          { args: ["-e", source], env: {} },
          {
            signal: controller.signal,
            events: {
              stdout(chunk) {
                text += chunk;
                if (text.includes("\n")) {
                  pid = Number(text.trim());
                  controller.abort(new Error("cancelled running process"));
                }
              },
            },
          },
        ),
      Error,
      "cancelled running process",
    );
    assertEquals(pid > 0, true);
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        process.kill(pid, 0);
        if (process.platform === "linux") {
          const { readFile } = await import("node:fs/promises");
          const stat = await readFile("/proc/" + pid + "/stat", "utf8");
          if (stat.slice(stat.lastIndexOf(")") + 2).startsWith("Z ")) return;
        }
      } catch (error) {
        if (
          error instanceof Error &&
          "code" in error &&
          ["ESRCH", "ENOENT"].includes(String(error.code))
        )
          return;
        throw error;
      }
      await Bun.sleep(10);
    }
    throw new Error("Cancelled descendant is still running");
  } finally {
    if (pid > 0) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        /* Already reaped. */
      }
    }
  }
});
