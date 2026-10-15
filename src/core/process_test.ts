import { test } from "bun:test";

import { assertEquals } from "../test/assert.ts";
import { runInvocation } from "./process.ts";

test("captures and streams stdout while streaming stderr", async () => {
  let streamedStdout = "";
  let streamedStderr = "";
  const result = await runInvocation(
    process.execPath,
    {
      args: ["-e", 'console.log(process.env["BUNDLR_PROCESS_TEST"]); console.error("problem")'],
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
