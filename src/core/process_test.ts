import { assertEquals } from "jsr:@std/assert@1.0.14";
import { runInvocation } from "./process.ts";

Deno.test("captures and streams stdout while streaming stderr", async () => {
  let streamedStdout = "";
  let streamedStderr = "";
  const result = await runInvocation(
    Deno.execPath(),
    {
      args: [
        "eval",
        'console.log(Deno.env.get("BUNDLR_PROCESS_TEST")); console.error("problem")',
      ],
      env: { BUNDLR_PROCESS_TEST: "ready" },
    },
    {
      captureStdout: true,
      events: {
        stdout: (text) => streamedStdout += text,
        stderr: (text) => streamedStderr += text,
      },
    },
  );

  assertEquals(result, { success: true, code: 0, stdout: "ready\n" });
  assertEquals(streamedStdout, "ready\n");
  assertEquals(streamedStderr, "problem\n");
});

Deno.test("returns a non-zero child exit code", async () => {
  const result = await runInvocation(Deno.execPath(), {
    args: ["eval", "Deno.exit(7)"],
    env: {},
  });

  assertEquals(result, { success: false, code: 7 });
});
