import { packageTargets } from "./core/package_application.ts";
import { currentTarget } from "./core/target.ts";
import {
  type ApplicationKind,
  type PackageRequest,
  validatePackageRequest,
} from "./domain/package_request.ts";
import { parsePackageSource } from "./domain/source.ts";
import { BUNDLR_VERSION } from "./version.ts";

export async function startDesktop(): Promise<void> {
  const token = crypto.randomUUID();
  let handle!: (request: Request) => Promise<Response>;
  let finished!: () => void;
  const stopped = new Promise<void>((resolve) => {
    finished = resolve;
  });
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    development: false,
    fetch(request, server) {
      if (new URL(request.url).pathname === "/package")
        server.timeout(request, 0);
      return handle(request);
    },
  });
  const origin = server.url.origin;
  const quit = () => {
    void handle(
      new Request(origin + "/quit", {
        method: "POST",
        headers: { host: server.url.host, origin, "x-bundlr-token": token },
      }),
    );
  };
  handle = createDesktopHandler(origin, token, async () => {
    process.off("SIGINT", quit);
    process.off("SIGTERM", quit);
    await server.stop();
    finished();
  });
  process.once("SIGINT", quit);
  process.once("SIGTERM", quit);
  console.log("Bundlr browser interface: " + origin + "/");
  if (process.env.BUNDLR_NO_BROWSER !== "1") {
    const opener =
      process.platform === "win32"
        ? "explorer.exe"
        : process.platform === "darwin"
          ? "open"
          : "xdg-open";
    try {
      Bun.spawn([opener, origin + "/"], {
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
        windowsHide: true,
      }).unref();
    } catch {
      console.error("Open the address above in your browser.");
    }
  }
  await stopped;
}

export function createDesktopHandler(
  origin: string,
  token: string,
  shutdown: () => Promise<void>,
  build: typeof packageTargets = packageTargets,
): (request: Request) => Promise<Response> {
  let active: AbortController | undefined;
  let stopping = false;
  let finished: Promise<void> | undefined;
  const host = new URL(origin).host;
  const encoder = new TextEncoder();
  return async (request) => {
    if (request.headers.get("host") !== host)
      return new Response("Forbidden", { status: 403 });
    const route = new URL(request.url).pathname;
    if (request.method === "GET" && route === "/") {
      return new Response(page(currentTarget(), token), {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-store",
          "content-security-policy":
            "default-src 'none'; style-src 'unsafe-inline'; " +
            "script-src 'nonce-" +
            token +
            "'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
        },
      });
    }
    const from = request.headers.get("origin");
    if (
      request.method !== "POST" ||
      request.headers.get("x-bundlr-token") !== token ||
      (from !== null && from !== origin)
    )
      return new Response("Forbidden", { status: 403 });
    if (route === "/cancel") {
      active?.abort(new Error("Cancelled by the user."));
      return new Response(null, { status: 204 });
    }
    if (route === "/quit") {
      stopping = true;
      active?.abort(new Error("Bundlr is shutting down."));
      void Promise.resolve(finished)
        .then(shutdown)
        .catch((error) => console.error(error));
      return new Response(null, { status: 204 });
    }
    if (route !== "/package") return new Response("Not found", { status: 404 });
    let packaging: PackageRequest;
    try {
      const body = await request.text();
      if (body.length > 65536)
        return new Response("Request too large", { status: 413 });
      packaging = validatePackageRequest(decodeRequest(JSON.parse(body)));
    } catch (error) {
      return new Response(
        error instanceof Error ? error.message : String(error),
        { status: 400 },
      );
    }
    if (stopping || active !== undefined) {
      return new Response("A build is already running or Bundlr is stopping.", {
        status: 409,
      });
    }
    const abort = new AbortController();
    active = abort;
    let closed = false;
    const disconnect = () => {
      closed = true;
      abort.abort(new Error("Browser disconnected."));
    };
    request.signal.addEventListener("abort", disconnect, { once: true });
    if (request.signal.aborted) disconnect();
    return new Response(
      new ReadableStream<Uint8Array>({
        start(stream) {
          const send = (message: object) => {
            if (!closed)
              stream.enqueue(encoder.encode(JSON.stringify(message) + "\n"));
          };
          finished = Promise.resolve()
            .then(() =>
              build(
                packaging,
                {
                  stdout: (text) =>
                    send({ type: "output", stream: "stdout", text }),
                  stderr: (text) =>
                    send({ type: "output", stream: "stderr", text }),
                },
                abort.signal,
              ),
            )
            .then(
              (results) => send({ type: "done", results }),
              (error: unknown) =>
                send({
                  type: "error",
                  message:
                    error instanceof Error ? error.message : String(error),
                }),
            )
            .finally(() => {
              request.signal.removeEventListener("abort", disconnect);
              active = undefined;
              if (!closed) stream.close();
            });
        },
        cancel: disconnect,
      }),
      { headers: { "content-type": "application/x-ndjson; charset=utf-8" } },
    );
  };
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
    typeof value.python === "string" && value.python.length > 0
      ? value.python
      : "3.12";
  const outputDirectory =
    typeof value.outputDirectory === "string" &&
    value.outputDirectory.length > 0
      ? value.outputDirectory
      : "dist";
  const source = parsePackageSource(value.source as string);
  const applicationName =
    typeof value.applicationName === "string" &&
    value.applicationName.length > 0
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

function inferApplicationName(
  source: ReturnType<typeof parsePackageSource>,
): string {
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
  if (
    !Array.isArray(value) ||
    value.length === 0 ||
    value.some((item) => !supported.has(item))
  ) {
    throw new Error("Select at least one supported target platform.");
  }
  return value as PackageRequest["targets"];
}

function decodeApplicationKind(value: unknown): ApplicationKind {
  if (value === "auto" || value === "console" || value === "windowed")
    return value;
  throw new Error("Application kind must be auto, console, or windowed.");
}

export function page(target: string, token: string): string {
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
      </div>
      <button id="quit" type="button">Quit Bundlr</button>
    </form>
    <div id="status" role="status"></div>
    <pre id="output" aria-label="Packaging output"></pre>
  </main>
  <script nonce="${token}">
    const form = document.querySelector("#form");
    const packageButton = document.querySelector("#package");
    const cancel = document.querySelector("#cancel");
    const status = document.querySelector("#status");
    const output = document.querySelector("#output");

    const token = ${JSON.stringify(token)};
    const post = (route, value) => fetch(route, {
      method: "POST",
      headers: {"x-bundlr-token": token, "content-type": "application/json"},
      body: value === undefined ? undefined : JSON.stringify(value),
    });
    const receiveOutput = (stream, text) => {
      const span = document.createElement("span");
      if (stream === "stderr") span.className = "stderr";
      span.textContent = text;
      output.append(span);
      output.scrollTop = output.scrollHeight;
    };

    let stopped = false;
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      output.textContent = "";
      status.textContent = "Packaging application…";
      packageButton.disabled = true;
      cancel.disabled = false;
      try {
        const response = await post("/package", {
          source: document.querySelector("#source").value,
          applicationName: document.querySelector("#applicationName").value,
          command: document.querySelector("#command").value,
          applicationKind: document.querySelector("#applicationKind").value,
          python: document.querySelector("#python").value,
          outputDirectory: document.querySelector("#outputDirectory").value,
          targets: [...document.querySelectorAll('input[name="target"]:checked')]
            .map((input) => input.value),
        });
        if (!response.ok) throw new Error(await response.text());
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let pending = "";
        let completed = false;
        try {
          for (;;) {
            const {done, value} = await reader.read();
            pending += decoder.decode(value, {stream: !done});
            let separator;
            while ((separator = pending.indexOf("\\n")) !== -1) {
              const event = JSON.parse(pending.slice(0, separator));
              pending = pending.slice(separator + 1);
              if (event.type === "output") receiveOutput(event.stream, event.text);
              if (event.type === "error") throw new Error(event.message);
              if (event.type === "done") {
                completed = true;
                if (!stopped) status.textContent = "Created " + event.results.map((result) => result.archivePath).join(", ") + ".";
              }
            }
            if (done) break;
          }
          if (!completed) throw new Error("Bundlr stopped before reporting a result.");
        } finally {
          await reader.cancel().catch(() => {});
          reader.releaseLock();
        }
      } catch (error) {
        if (!stopped) status.textContent = "Error: " + (error.message ?? String(error));
      } finally {
        if (!stopped) packageButton.disabled = false;
        cancel.disabled = true;
      }
    });

    cancel.addEventListener("click", async () => {
      status.textContent = "Cancelling…";
      await post("/cancel");
    });
    document.querySelector("#quit").addEventListener("click", async () => {
      try {
        const response = await post("/quit");
        if (!response.ok) throw new Error(await response.text());
        stopped = true;
        form.querySelectorAll("button, input, select").forEach((element) => element.disabled = true);
        status.textContent = "Bundlr stopped.";
      } catch (error) {
        status.textContent = "Could not stop Bundlr: " + (error.message ?? String(error));
      }
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
