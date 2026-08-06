import { packageTargets } from "./core/package_targets.ts";
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
    const request = decodeRequest(input);
    const controller = new AbortController();
    activeBuild = controller;
    try {
      return await packageTargets(request, {
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
  const python = typeof value.python === "string" && value.python.length > 0
    ? value.python
    : "3.12";
  const outputDirectory = typeof value.outputDirectory === "string" &&
      value.outputDirectory.length > 0
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
  const name = source.kind === "pypi"
    ? /^([A-Za-z0-9][A-Za-z0-9._-]*)/.exec(source.requirement)?.[1]
    : source.url.pathname.split("/").filter(Boolean).at(-1)?.split("@", 1)[0]?.replace(
      /\.git$/,
      "",
    );
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
        const results = await bindings.packageApplication({
          source: document.querySelector("#source").value,
          applicationName: document.querySelector("#applicationName").value,
          command: document.querySelector("#command").value,
          applicationKind: document.querySelector("#applicationKind").value,
          python: document.querySelector("#python").value,
          outputDirectory: document.querySelector("#outputDirectory").value,
          targets: [...document.querySelectorAll('input[name="target"]:checked')]
            .map((input) => input.value),
        });
        status.textContent = "Created " + results.map((result) => result.archivePath).join(", ") + ".";
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

function targetOption(value: string, label: string, current: string): string {
  return `<label><input type="checkbox" name="target" value="${value}" ${
    value === current ? "checked" : ""
  }>${label}</label>`;
}
