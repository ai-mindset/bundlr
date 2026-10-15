import { packageTargets } from "./core/package_targets.ts";
import { currentTarget } from "./core/target.ts";
import type { ApplicationKind, PackageRequest } from "./domain/package_request.ts";
import { parsePackageSource } from "./domain/source.ts";
import { main } from "./main.ts";
import { BUNDLR_VERSION } from "./version.ts";

const headers = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'",
};

if (import.meta.main) {
  if (process.argv.length > 2) {
    process.exitCode = await main(process.argv.slice(2));
  } else {
    startDesktop();
  }
}

function startDesktop(): void {
  const target = currentTarget();
  const token = crypto.randomUUID();
  let activeBuild: AbortController | undefined;
  const sessions = new Map<string, number>();
  const openedAt = Date.now();
  const sessionLeaseMs = 10 * 60 * 1000;
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  let stopped = false;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request, server) {
      const url = new URL(request.url);
      if (url.origin !== server.url.origin) return new Response("Forbidden", { status: 403 });
      if (url.pathname === "/" && request.method === "GET") {
        if (closeTimer !== undefined) clearTimeout(closeTimer);
        const pageId = crypto.randomUUID();
        sessions.set(pageId, Date.now());
        return new Response(page(target, token, pageId), { headers });
      }
      if (
        request.method !== "POST" ||
        request.headers.get("x-bundlr-token") !== token ||
        (request.headers.has("origin") && request.headers.get("origin") !== server.url.origin)
      ) {
        return new Response("Forbidden", { status: 403 });
      }
      if (url.pathname === "/cancel") {
        activeBuild?.abort("Cancelled by the user.");
        return new Response(null, { status: 204 });
      }
      if (url.pathname === "/close") {
        sessions.delete(request.headers.get("x-bundlr-page") ?? "");
        if (sessions.size === 0) {
          if (closeTimer !== undefined) clearTimeout(closeTimer);
          // A reload requests the page again and cancels this short grace period.
          closeTimer = setTimeout(stopDesktop, 2000);
        }
        return new Response(null, { status: 204 });
      }
      if (url.pathname === "/heartbeat") {
        const pageId = request.headers.get("x-bundlr-page");
        if (pageId !== null && sessions.has(pageId)) sessions.set(pageId, Date.now());
        return new Response(null, { status: 204 });
      }
      if (url.pathname === "/quit") {
        setTimeout(stopDesktop, 0);
        return new Response(null, { status: 204 });
      }
      if (url.pathname !== "/package") return new Response("Not found", { status: 404 });
      if (activeBuild !== undefined)
        return new Response("A package build is already running.", { status: 409 });
      let packageRequest: PackageRequest;
      try {
        packageRequest = decodeRequest(await request.json());
      } catch (error) {
        return new Response(error instanceof Error ? error.message : String(error), {
          status: 400,
        });
      }
      const controller = new AbortController();
      activeBuild = controller;
      server.timeout(request, 0);
      let connected = true;
      const encoder = new TextEncoder();
      const stream = new ReadableStream<Uint8Array>({
        async start(output) {
          const send = (value: unknown) => {
            if (connected) output.enqueue(encoder.encode(JSON.stringify(value) + "\n"));
          };
          try {
            const results = await packageTargets(
              packageRequest,
              {
                stdout: (text) => send({ type: "output", stream: "stdout", text }),
                stderr: (text) => send({ type: "output", stream: "stderr", text }),
              },
              controller.signal,
            );
            send({ type: "done", results });
          } catch (error) {
            send({
              type: "error",
              message: error instanceof Error ? error.message : String(error),
            });
          } finally {
            activeBuild = undefined;
            if (connected) output.close();
          }
        },
        cancel() {
          connected = false;
          controller.abort("Browser disconnected.");
        },
      });
      return new Response(stream, {
        headers: {
          "content-type": "application/x-ndjson; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    },
  });
  const cleanupTimer = setInterval(() => {
    const now = Date.now();
    for (const [pageId, lastSeen] of sessions) {
      if (now - lastSeen > sessionLeaseMs) sessions.delete(pageId);
    }
    if (sessions.size === 0 && now - openedAt > sessionLeaseMs) stopDesktop();
  }, 60_000);
  function stopDesktop(): void {
    if (stopped) return;
    stopped = true;
    clearInterval(cleanupTimer);
    if (closeTimer !== undefined) clearTimeout(closeTimer);
    activeBuild?.abort("Desktop interface closed.");
    void server.stop();
  }
  const url = server.url.href;
  console.log(`Bundlr desktop interface: ${url}`);
  const command =
    process.platform === "darwin"
      ? ["open", url]
      : process.platform === "win32"
        ? ["explorer.exe", url]
        : ["xdg-open", url];
  try {
    Bun.spawn(command, { stdin: "ignore", stdout: "ignore", stderr: "ignore", windowsHide: true });
  } catch {
    // The printed URL remains usable when no desktop opener is available.
  }
}

function decodeRequest(input: unknown): PackageRequest {
  if (typeof input !== "object" || input === null) {
    throw new Error("Invalid package request.");
  }
  const value = input as Record<string, unknown>;
  const required = ["source"] as const;
  for (const field of required) {
    if (typeof value[field] !== "string") {
      throw new Error("Package source is required.");
    }
  }
  const applicationKind = decodeApplicationKind(value.applicationKind);
  const python =
    typeof value.python === "string" && value.python.length > 0 ? value.python : "3.12";
  const outputDirectory =
    typeof value.outputDirectory === "string" && value.outputDirectory.length > 0
      ? value.outputDirectory
      : "dist";
  const source = parsePackageSource(value.source as string);
  const applicationName =
    typeof value.applicationName === "string" && value.applicationName.length > 0
      ? value.applicationName
      : inferApplicationName(source);
  return {
    source,
    applicationName,
    applicationKind,
    command: typeof value.command === "string" ? value.command : "",
    python,
    targets: decodeTargets(value.targets),
    outputDirectory,
  };
}

function inferApplicationName(source: ReturnType<typeof parsePackageSource>): string {
  const name =
    source.kind === "pypi"
      ? /^([A-Za-z0-9][A-Za-z0-9._-]*)/.exec(source.requirement)?.[1]
      : source.url.pathname
          .split("/")
          .filter(Boolean)
          .at(-1)
          ?.split("@", 1)[0]
          ?.replace(/\.git$/, "");
  if (name === undefined) throw new Error("Enter an application name.");
  return name;
}

function decodeTargets(value: unknown): PackageRequest["targets"] {
  const supported = new Set<PackageRequest["targets"][number]>([
    "linux-x86_64",
    "macos-arm64",
    "macos-x86_64",
    "windows-x86_64",
  ]);
  if (!Array.isArray(value) || value.length === 0 || value.some((item) => !supported.has(item))) {
    throw new Error("Select at least one supported target platform.");
  }
  return value as PackageRequest["targets"];
}

function decodeApplicationKind(value: unknown): ApplicationKind {
  if (value === "auto" || value === "console" || value === "windowed") return value;
  throw new Error("Application kind must be auto, console, or windowed.");
}

export function page(target: string, token: string, pageId: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Bundlr</title>
  <style>
    :root { color-scheme: light dark; font: 15px system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; background: Canvas; color: CanvasText; }
    main { max-width: 720px; margin: auto; padding: 28px; }
    h1 { margin: 0; font-size: 28px; }
    .subtitle { margin: 4px 0 24px; color: GrayText; }
    label { display: block; margin: 14px 0 6px; font-weight: 600; }
    input, select, button { font: inherit; }
    input, select {
      width: 100%; padding: 10px 12px; border: 1px solid GrayText; border-radius: 6px;
      background: Field; color: FieldText;
    }
    .row { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
    fieldset { margin: 14px 0 0; padding: 10px 12px; border: 1px solid GrayText; border-radius: 6px; }
    legend { font-weight: 600; }
    .targets { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
    .targets label { display: flex; gap: 8px; align-items: center; margin: 0; font-weight: 400; }
    .targets input { width: auto; }
    .actions { display: flex; gap: 10px; margin: 18px 0; }
    details { margin-top: 14px; }
    summary { cursor: pointer; font-weight: 600; }
    button { padding: 9px 18px; border: 0; border-radius: 6px; cursor: pointer; }
    #package { background: #2563eb; color: white; }
    #cancel { background: #dc2626; color: white; }
    #quit { margin-left: auto; }
    button:disabled { opacity: .5; cursor: default; }
    #status { min-height: 22px; color: GrayText; }
    pre {
      min-height: 160px; max-height: 240px; overflow: auto; margin: 8px 0 0; padding: 12px;
      border-radius: 6px; background: #111827; color: #e5e7eb; white-space: pre-wrap;
    }
    .stderr { color: #fca5a5; }
  </style>
</head>
<body>
  <main>
    <h1>Bundlr</h1>
    <p class="subtitle">Package a Python application for ${target}. Version ${BUNDLR_VERSION}</p>
    <form id="form">
      <label for="source">PyPI requirement or HTTPS Git URL</label>
      <input id="source" required placeholder="example-app==1.0.0">
      <div class="row">
        <div>
          <label for="applicationName">Application name</label>
          <input id="applicationName" placeholder="Auto-detect">
        </div>
        <div>
          <label for="command">Application entry point</label>
          <input id="command" placeholder="Auto-detect">
        </div>
      </div>
      <div class="row">
        <div>
          <label for="applicationKind">Application kind</label>
          <select id="applicationKind">
            <option value="auto">Auto-detect</option>
            <option value="windowed">Windowed</option>
            <option value="console">Console</option>
          </select>
        </div>
        <div>
          <label for="python">Python version</label>
          <input id="python" value="3.12">
        </div>
      </div>
      <label for="outputDirectory">Output directory</label>
      <input id="outputDirectory" value="dist">
      <fieldset>
        <legend>Target platforms</legend>
        <div class="targets">
          ${targetOption("linux-x86_64", "Linux x64", target)}
          ${targetOption("windows-x86_64", "Windows x64", target)}
          ${targetOption("macos-arm64", "macOS Apple Silicon", target)}
          ${targetOption("macos-x86_64", "macOS Intel", target)}
        </div>
      </fieldset>
      <div class="actions">
        <button id="package" type="submit">Package</button>
        <button id="cancel" type="button" disabled>Cancel</button>
        <button id="quit" type="button">Quit Bundlr</button>
      </div>
    </form>
    <div id="status" role="status"></div>
    <pre id="output" aria-label="Packaging output"></pre>
  </main>
  <script>
    const token = ${JSON.stringify(token)};
    const pageId = ${JSON.stringify(pageId)};
    const form = document.querySelector("#form");
    const packageButton = document.querySelector("#package");
    const cancel = document.querySelector("#cancel");
    const quit = document.querySelector("#quit");
    const status = document.querySelector("#status");
    const output = document.querySelector("#output");

    globalThis.receiveOutput = (stream, text) => {
      const span = document.createElement("span");
      if (stream === "stderr") span.className = "stderr";
      span.textContent = text;
      output.append(span);
      output.scrollTop = output.scrollHeight;
    };

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      output.textContent = "";
      status.textContent = "Packaging application…";
      packageButton.disabled = true;
      cancel.disabled = false;
      try {
        const response = await fetch("/package", {
          method: "POST",
          headers: { "content-type": "application/json", "x-bundlr-token": token },
          body: JSON.stringify({
          source: document.querySelector("#source").value,
          applicationName: document.querySelector("#applicationName").value,
          command: document.querySelector("#command").value,
          applicationKind: document.querySelector("#applicationKind").value,
          python: document.querySelector("#python").value,
          outputDirectory: document.querySelector("#outputDirectory").value,
          targets: [...document.querySelectorAll('input[name="target"]:checked')]
            .map((input) => input.value),
          }),
        });
        if (!response.ok || !response.body) throw new Error(await response.text());
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let pending = "";
        let completed = false;
        while (true) {
          const { done, value } = await reader.read();
          pending += decoder.decode(value, { stream: !done });
          const lines = pending.split("\\n");
          pending = lines.pop() ?? "";
          for (const line of lines) {
            if (!line) continue;
            const event = JSON.parse(line);
            if (event.type === "output") receiveOutput(event.stream, event.text);
            if (event.type === "error") throw new Error(event.message);
            if (event.type === "done") {
              completed = true;
              status.textContent = "Created " + event.results.map((result) => result.archivePath).join(", ") + ".";
            }
          }
          if (done) break;
        }
        if (!completed) throw new Error("Packaging connection closed unexpectedly.");
      } catch (error) {
        status.textContent = "Error: " + (error.message ?? String(error));
      } finally {
        packageButton.disabled = false;
        cancel.disabled = true;
      }
    });

    cancel.addEventListener("click", async () => {
      status.textContent = "Cancelling…";
      await fetch("/cancel", { method: "POST", headers: { "x-bundlr-token": token } });
    });

    quit.addEventListener("click", async () => {
      await fetch("/quit", { method: "POST", headers: { "x-bundlr-token": token } });
      clearInterval(heartbeat);
      form.querySelectorAll("button, input, select").forEach((control) => control.disabled = true);
      status.textContent = "Bundlr has stopped. You can close this tab.";
    });

    const heartbeat = setInterval(() => {
      void fetch("/heartbeat", {
        method: "POST",
        headers: { "x-bundlr-token": token, "x-bundlr-page": pageId },
      }).catch(() => {});
    }, 30_000);

    addEventListener("pagehide", () => {
      void fetch("/close", {
        method: "POST",
        headers: { "x-bundlr-token": token, "x-bundlr-page": pageId },
        keepalive: true,
      });
    });
  </script>
</body>
</html>`;
}

function targetOption(value: string, label: string, current: string): string {
  return `<label><input type="checkbox" name="target" value="${value}" ${
    value === current ? "checked" : ""
  }>${label}</label>`;
}
