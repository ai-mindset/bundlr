import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import lock from "../build-lock.json";
import { executablePath } from "../tests/helpers.ts";
import { verifyRecipient } from "../tests/recipient.ts";
const args = process.argv.slice(2).filter((arg) => arg !== "--");
if (args.length > 1 || process.platform !== "linux")
  throw new Error("Usage on Linux: bun scripts/browser_smoke.ts [binary]");
const chrome =
  process.env.BUNDLR_SMOKE_CHROME ??
  Bun.which("google-chrome") ??
  Bun.which("chromium") ??
  Bun.which("chromium-browser");
if (!chrome)
  throw new Error(
    "A real Chrome/Chromium executable is required; set BUNDLR_SMOKE_CHROME.",
  );
const binary = resolve(args[0] ?? executablePath());
const base = await mkdtemp(join(tmpdir(), "bundlr-browser-"));
const env = {
  ...process.env,
  BUNDLR_NO_BROWSER: "1",
  BUNDLR_CACHE_DIRECTORY: join(base, "tool-cache"),
  BUNDLR_PYTHON_CACHE_DIRECTORY:
    process.env.BUNDLR_PYTHON_CACHE_DIRECTORY ?? join(base, "python-cache"),
};
const app = Bun.spawn([binary], { env, stdout: "pipe", stderr: "pipe" });
let appLog = "";
async function consume(stream: ReadableStream<Uint8Array>) {
  for await (const chunk of stream) appLog += new TextDecoder().decode(chunk);
}
const logs = Promise.all([consume(app.stdout), consume(app.stderr)]);
let browser: ReturnType<typeof Bun.spawn> | undefined;
let socket: WebSocket | undefined;
const pending = new Map<
  number,
  {
    resolve: (value: Record<string, any>) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }
>();
let id = 0;
const exceptions: unknown[] = [];
async function waitFor<T>(
  get: () => Promise<T>,
  accept: (value: T) => boolean,
  label: string,
  timeout = 30000,
): Promise<T> {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    const value = await get();
    if (accept(value)) return value;
    await Bun.sleep(30);
  }
  throw new Error("Timed out waiting for " + label);
}
async function call(
  method: string,
  params: object = {},
): Promise<Record<string, any>> {
  const key = ++id;
  return await new Promise((resolve_, reject) => {
    const timer = setTimeout(() => {
      pending.delete(key);
      reject(new Error("CDP timeout: " + method));
    }, 30000);
    pending.set(key, { resolve: resolve_, reject, timer });
    socket!.send(JSON.stringify({ id: key, method, params }));
  });
}
async function evaluate(expression: string): Promise<any> {
  const response = await call("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (response.exceptionDetails)
    throw new Error(JSON.stringify(response.exceptionDetails));
  return response.result?.value;
}
async function status(prefix: string, timeout = 300000): Promise<string> {
  return await waitFor(
    async () => {
      const text = String(
        await evaluate('document.querySelector("#status").textContent'),
      );
      if (text.startsWith("Error:") && prefix !== "Error:")
        throw new Error(text);
      return text;
    },
    (text) => text.startsWith(prefix),
    "browser status " + prefix,
    timeout,
  );
}
async function fill(selector: string, value: string) {
  await evaluate(
    "document.querySelector(" +
      JSON.stringify(selector) +
      ").value = " +
      JSON.stringify(value),
  );
}
async function click(selector: string) {
  await evaluate(
    "document.querySelector(" + JSON.stringify(selector) + ").click()",
  );
}
async function stop(child: ReturnType<typeof Bun.spawn>) {
  if (child.exitCode !== null) {
    await child.exited;
    return;
  }
  if (child.exitCode === null) child.kill("SIGTERM");
  try {
    await waitForExit(child, 5000);
  } catch {
    if (child.exitCode === null) child.kill("SIGKILL");
  }
  await child.exited;
}
async function waitForExit(
  child: ReturnType<typeof Bun.spawn>,
  timeout: number,
): Promise<number> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      child.exited,
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("Process did not exit before timeout")),
          timeout,
        );
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
try {
  const origin = await waitFor(
    async () => {
      if (app.exitCode !== null)
        throw new Error("Bundlr failed to start: " + appLog);
      return /http:\/\/127\.0\.0\.1:\d+/.exec(appLog)?.[0] ?? "";
    },
    Boolean,
    "Bundlr loopback server",
  );
  const html = await (await fetch(origin)).text();
  const tokenLiteral = /const token = ("[^"]+")/.exec(html)?.[1];
  assert.ok(tokenLiteral, "Missing session token");
  const token = JSON.parse(tokenLiteral);
  const forbiddenHeaders: Record<string, string>[] = [
    {},
    { host: "attacker.example", "x-bundlr-token": token },
    { origin: "https://attacker.example", "x-bundlr-token": token },
  ];
  for (const headers of forbiddenHeaders) {
    const response = await fetch(origin + "/quit", {
      method: "POST",
      headers: { connection: "close", ...headers },
    });
    assert.equal(response.status, 403);
    await response.text();
  }
  const invalid = await fetch(origin + "/package", {
    method: "POST",
    headers: { "x-bundlr-token": token, origin, connection: "close" },
    body: JSON.stringify({
      source: "unpinned",
      targets: ["linux-x86_64"],
      applicationKind: "auto",
    }),
  });
  assert.equal(invalid.status, 400);
  await invalid.text();
  const profile = join(base, "chrome");
  await mkdir(profile);
  browser = Bun.spawn(
    [
      chrome,
      "--headless=new",
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--no-default-browser-check",
      "--remote-debugging-port=0",
      "--user-data-dir=" + profile,
      origin,
    ],
    { stdout: "ignore", stderr: Bun.file(join(base, "chrome.log")) },
  );
  const port = await waitFor(
    async () => {
      if (browser!.exitCode !== null)
        throw new Error(
          "Chrome exited: " +
            (await readFile(join(base, "chrome.log"), "utf8")),
        );
      try {
        return Number(
          (await readFile(join(profile, "DevToolsActivePort"), "utf8")).split(
            "\n",
          )[0],
        );
      } catch (error) {
        if (
          error instanceof Error &&
          "code" in error &&
          error.code === "ENOENT"
        )
          return 0;
        throw error;
      }
    },
    (value) => value > 0,
    "Chrome DevToolsActivePort",
  );
  const pages = (await (
    await fetch("http://127.0.0.1:" + port + "/json/list")
  ).json()) as { type: string; webSocketDebuggerUrl: string }[];
  const page = pages.find((value) => value.type === "page");
  assert.ok(page);
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(String(event.data));
    if (message.method === "Runtime.exceptionThrown")
      exceptions.push(message.params);
    const item = pending.get(message.id);
    if (item) {
      clearTimeout(item.timer);
      pending.delete(message.id);
      if (message.error) item.reject(new Error(JSON.stringify(message.error)));
      else item.resolve(message.result ?? {});
    }
  });
  await new Promise<void>((resolve_, reject) => {
    socket!.addEventListener("open", () => resolve_(), { once: true });
    socket!.addEventListener(
      "error",
      () => reject(new Error("CDP connection failed")),
      { once: true },
    );
  });
  await call("Runtime.enable");
  await waitFor(
    () => evaluate('Boolean(document.querySelector("#package"))'),
    Boolean,
    "form",
  );
  assert.equal(await evaluate("document.title"), "Bundlr");
  await fill("#source", "unpinned");
  await click("#package");
  assert.match(await status("Error:"), /pinned/i);
  const output = join(base, "applications");
  await fill("#source", "black==" + lock.acceptance.blackVersion);
  await fill("#command", "black");
  await fill("#applicationName", "BlackBrowser");
  await fill("#outputDirectory", output);
  await click("#package");
  await waitFor(
    () => evaluate('document.querySelector("#output").textContent'),
    (text) => String(text).includes("Packaging"),
    "streamed build output",
  );
  const busy = await fetch(origin + "/package", {
    method: "POST",
    headers: { "x-bundlr-token": token, origin, connection: "close" },
    body: JSON.stringify({
      source: "black==" + lock.acceptance.blackVersion,
      applicationKind: "console",
      targets: ["linux-x86_64"],
    }),
  });
  assert.equal(busy.status, 409);
  await busy.text();
  await click("#cancel");
  assert.match(await status("Error:"), /cancel|abort/i);
  try {
    assert.deepEqual(await readdir(output), []);
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT"))
      throw error;
  }
  await click("#package");
  await status("Created ");
  await verifyRecipient(
    join(output, "BlackBrowser-linux-x86_64.tar.gz"),
    join(base, "recipient"),
    "BlackBrowser",
    "linux-x86_64",
  );
  await fill("#outputDirectory", join(base, "shutdown"));
  await click("#package");
  await waitFor(
    () => evaluate('document.querySelector("#output").textContent'),
    (text) => String(text).includes("Packaging"),
    "shutdown build",
  );
  await click("#quit");
  await status("Bundlr stopped.");
  await waitForExit(app, 20000);
  assert.equal(app.exitCode, 0);
  assert.deepEqual(exceptions, []);
  try {
    assert.deepEqual(await readdir(join(base, "shutdown")), []);
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT"))
      throw error;
  }
  console.log(
    "Real browser validation, streaming, packaging, cancellation, concurrency, shutdown and recipient execution passed.",
  );
} finally {
  socket?.close();
  for (const item of pending.values()) {
    clearTimeout(item.timer);
    item.reject(new Error("CDP closed"));
  }
  if (browser) await stop(browser);
  await stop(app);
  await logs;
  await rm(base, { recursive: true, force: true });
}
