import { packageApplication } from "./core/package_application.ts";
import { currentTarget } from "./core/target.ts";
import type { ApplicationKind, PackageRequest } from "./domain/package_request.ts";
import { parsePackageSource } from "./domain/source.ts";
import { main } from "./main.ts";
import { BUNDLR_VERSION } from "./version.ts";

const headers = {
  "content-type": "text/html; charset=utf-8",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'",
};

if (Deno.args.length > 0) {
  Deno.exit(await main(Deno.args));
} else {
  startDesktop();
}

function startDesktop(): void {
  const target = currentTarget();
  Deno.serve(() => new Response(page(target), { headers }));
  const window = new Deno.BrowserWindow({
    title: "Bundlr",
    width: 760,
    height: 720,
  });
  let activeBuild: AbortController | undefined;

  window.bind("packageApplication", async (input: unknown) => {
    if (activeBuild !== undefined) throw new Error("A package build is already running.");
    const request = decodeRequest(input, target);
    const controller = new AbortController();
    activeBuild = controller;
    try {
      return await packageApplication(request, {
        stdout: (text) => sendOutput(window, "stdout", text),
        stderr: (text) => sendOutput(window, "stderr", text),
      }, controller.signal);
    } finally {
      activeBuild = undefined;
    }
  });

  window.bind("cancelPackaging", async () => {
    activeBuild?.abort("Cancelled by the user.");
    await Promise.resolve();
  });
}

function sendOutput(
  window: Deno.BrowserWindow,
  stream: "stdout" | "stderr",
  text: string,
): void {
  void window
    .executeJs(`globalThis.receiveOutput(${JSON.stringify(stream)}, ${JSON.stringify(text)})`)
    .catch(() => undefined);
}

function decodeRequest(input: unknown, target: PackageRequest["targets"][number]): PackageRequest {
  if (typeof input !== "object" || input === null) {
    throw new Error("Invalid package request.");
  }
  const value = input as Record<string, unknown>;
  const required = ["source", "applicationName", "command"] as const;
  for (const field of required) {
    if (typeof value[field] !== "string") {
      throw new Error("Package source, application name, and command are required.");
    }
  }
  const applicationKind = decodeApplicationKind(value.applicationKind);
  const python = typeof value.python === "string" && value.python.length > 0
    ? value.python
    : "3.12";
  const outputDirectory = typeof value.outputDirectory === "string" &&
      value.outputDirectory.length > 0
    ? value.outputDirectory
    : "dist";
  const collectPackages = typeof value.collectPackages === "string"
    ? value.collectPackages.split(",").map((name) => name.trim()).filter(Boolean)
    : [];

  return {
    source: parsePackageSource(value.source as string),
    applicationName: value.applicationName as string,
    applicationKind,
    command: value.command as string,
    python,
    targets: [target],
    outputDirectory,
    ...(collectPackages.length === 0 ? {} : { collectPackages }),
  };
}

function decodeApplicationKind(value: unknown): ApplicationKind {
  if (value === "console" || value === "windowed") return value;
  throw new Error("Application kind must be console or windowed.");
}

function page(target: string): string {
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
          <input id="applicationName" required placeholder="Example App">
        </div>
        <div>
          <label for="command">Application entry point</label>
          <input id="command" required placeholder="example-app">
        </div>
      </div>
      <div class="row">
        <div>
          <label for="applicationKind">Application kind</label>
          <select id="applicationKind">
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
      <details>
        <summary>Advanced packaging</summary>
        <label for="collectPackages">Collect packages</label>
        <input id="collectPackages" placeholder="textual, posting">
      </details>
      <div class="actions">
        <button id="package" type="submit">Package</button>
        <button id="cancel" type="button" disabled>Cancel</button>
      </div>
    </form>
    <div id="status" role="status"></div>
    <pre id="output" aria-label="Packaging output"></pre>
  </main>
  <script>
    const form = document.querySelector("#form");
    const packageButton = document.querySelector("#package");
    const cancel = document.querySelector("#cancel");
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
        const result = await bindings.packageApplication({
          source: document.querySelector("#source").value,
          applicationName: document.querySelector("#applicationName").value,
          command: document.querySelector("#command").value,
          applicationKind: document.querySelector("#applicationKind").value,
          python: document.querySelector("#python").value,
          outputDirectory: document.querySelector("#outputDirectory").value,
          collectPackages: document.querySelector("#collectPackages").value,
        });
        status.textContent = "Created " + result.artifactPath + ".";
      } catch (error) {
        status.textContent = "Error: " + (error.message ?? String(error));
      } finally {
        packageButton.disabled = false;
        cancel.disabled = true;
      }
    });

    cancel.addEventListener("click", async () => {
      status.textContent = "Cancelling…";
      await bindings.cancelPackaging();
    });
  </script>
</body>
</html>`;
}
