import { test } from "bun:test";
import { assertEquals, assertStringIncludes } from "./test/assert.ts";
import { createDesktopHandler, page } from "./desktop.ts";

const origin = "http://127.0.0.1:4000";
const token = "test-token";
const requestBody = JSON.stringify({
  source: "black==26.5.1",
  applicationKind: "auto",
  targets: ["linux-x86_64"],
});

function post(
  route: string,
  body?: string,
  overrides: Record<string, string> = {},
) {
  return new Request(origin + route, {
    method: "POST",
    headers: {
      host: "127.0.0.1:4000",
      origin,
      "x-bundlr-token": token,
      ...overrides,
    },
    body,
  });
}

test("desktop rejects foreign hosts, origins and missing credentials", async () => {
  let stopped = false;
  const handle = createDesktopHandler(origin, token, () => {
    stopped = true;
    return Promise.resolve();
  });
  assertEquals(
    (await handle(post("/quit", undefined, { host: "other.example" }))).status,
    403,
  );
  assertEquals(
    (
      await handle(
        post("/quit", undefined, { origin: "https://other.example" }),
      )
    ).status,
    403,
  );
  assertEquals(
    (await handle(post("/quit", undefined, { "x-bundlr-token": "" }))).status,
    403,
  );
  assertEquals(stopped, false);
  assertEquals((await handle(post("/package", "{}"))).status, 400);
  assertEquals((await handle(post("/quit"))).status, 204);
  assertEquals(stopped, true);
});

test("desktop streams output and cancels the active build", async () => {
  const handle = createDesktopHandler(
    origin,
    token,
    () => Promise.resolve(),
    (_request, events, signal) => {
      events?.stdout?.("starting\n");
      return new Promise((_, reject) => {
        signal?.addEventListener("abort", () => reject(signal.reason), {
          once: true,
        });
      });
    },
  );
  const response = await handle(post("/package", requestBody));
  assertEquals(response.status, 200);
  const reader = response.body!.getReader();
  const first = await reader.read();
  assertStringIncludes(
    new TextDecoder().decode(first.value),
    '"type":"output"',
  );
  assertEquals((await handle(post("/package", requestBody))).status, 409);
  assertEquals((await handle(post("/cancel"))).status, 204);
  const last = await reader.read();
  assertStringIncludes(
    new TextDecoder().decode(last.value),
    "Cancelled by the user.",
  );
  assertEquals((await reader.read()).done, true);
  reader.releaseLock();
});

test("browser script parses and contains the session nonce", () => {
  const html = page("linux-x86_64", "test-nonce");
  assertStringIncludes(html, 'nonce="test-nonce"');
  const script = /<script[^>]*>([\s\S]*?)<\/script>/.exec(html)?.[1];
  if (!script) throw new Error("Missing browser script");
  new Function(script);
});

test("quit waits for build cleanup and rejects new requests while stopping", async () => {
  let release!: () => void;
  const cleanup = new Promise<void>((resolve) => {
    release = resolve;
  });
  let stopped = false;
  const handle = createDesktopHandler(
    origin,
    token,
    async () => {
      stopped = true;
    },
    async (_request, events, signal) => {
      events?.stdout?.("started");
      await new Promise<void>((resolve) => {
        signal!.addEventListener("abort", () => resolve(), { once: true });
      });
      await cleanup;
      throw signal!.reason;
    },
  );
  const stream = await handle(post("/package", requestBody));
  const reader = stream.body!.getReader();
  await reader.read();
  assertEquals((await handle(post("/quit"))).status, 204);
  assertEquals(stopped, false);
  assertEquals((await handle(post("/package", requestBody))).status, 409);
  release();
  while (!(await reader.read()).done) {
    /* Drain cancellation output. */
  }
  reader.releaseLock();
  await Promise.resolve();
  assertEquals(stopped, true);
});
