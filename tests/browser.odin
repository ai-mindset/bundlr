#+feature dynamic-literals
package acceptance

import b "../src"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Background :: struct { process: os.Process, waited: bool, state: os.Process_State }
background :: proc(args: []string, log: string, env: []string = nil) -> (value: Background, failure: Error) {
    file, e := os.open(log, {.Write, .Create, .Excl, .Inheritable})
    if e != nil { return value, "Cannot create background process log." }
    defer os.close(file)
    command: [dynamic]string
    append(&command, self(), "--internal-exec")
    append(&command, ..args)
    process, pe := b.start_process({command = command[:], env = env, stdout = file, stderr = file})
    if pe != nil { return value, fmt.aprintf("Cannot start background process: %v", pe) }
    value.process = process
    return value, nil
}
poll_background :: proc(process: ^Background) -> Error {
    if process.waited { return nil }
    state, e := os.process_wait(process.process, 0)
    if e == .Timeout { return nil }
    if e != nil { return "Cannot poll background process." }
    if state.exited { process.state, process.waited = state, true }
    return nil
}
await_background :: proc(process: ^Background, timeout: time.Duration) -> Error {
    if process.waited { return nil }
    state, e := os.process_wait(process.process, timeout)
    if e != nil { return fmt.aprintf("Background process did not stop: %v", e) }
    process.state, process.waited = state, true
    return nil
}
stop_background :: proc(process: ^Background) {
    if process.waited { return }
    _ = os.process_terminate(process.process)
    if await_background(process, 5*time.Second) != nil {
        b.kill_tree(process.process)
        _ = await_background(process, 5*time.Second)
    }
}
find_chrome :: proc() -> string {
    if path := b.env("BUNDLR_SMOKE_CHROME"); path != "" { return path }
    for name in ([]string{"google-chrome", "chromium", "chromium-browser"}) {
        for directory in strings.split(b.env("PATH"), ":") {
            path := b.join(directory, name)
            info, e := os.stat(path, context.allocator)
            if e == nil && info.type == .Regular && info.mode&os.Permissions_Execute_All != {} { return path }
        }
    }
    return ""
}
browser_status :: proc(socket: ^WebSocket, prefix: string, timeout := 5*time.Minute) -> (value: string, failure: Error) {
    started := time.tick_now()
    for time.tick_since(started) < timeout {
        result := evaluate(socket, `document.querySelector("#status").textContent`) or_return
        value = json_string(result)
        if strings.has_prefix(value, prefix) { return value, nil }
        if strings.has_prefix(value, "Error:") && prefix != "Error:" { return "", value }
        time.sleep(30*time.Millisecond)
    }
    return "", fmt.aprintf("Timed out waiting for browser status %s.", prefix)
}
browser_fill :: proc(socket: ^WebSocket, selector, value: string) -> Error {
    _, e := evaluate(socket, fmt.aprintf("document.querySelector(%s).value = %s", b.json_text(selector), b.json_text(value)))
    return e
}
browser_click :: proc(socket: ^WebSocket, selector: string) -> Error {
    _, e := evaluate(socket, fmt.aprintf("document.querySelector(%s).click()", b.json_text(selector)))
    return e
}
browser_output :: proc(socket: ^WebSocket) -> Error {
    started := time.tick_now()
    for time.tick_since(started) < 30*time.Second {
        value := evaluate(socket, `document.querySelector("#output").textContent`) or_return
        if strings.contains(json_string(value), "Packaging") { return nil }
        time.sleep(30*time.Millisecond)
    }
    return "Browser did not receive streamed build output."
}
empty_output :: proc(path: string) -> Error {
    _, e := os.lstat(path, context.allocator)
    if e == .Not_Exist { return nil }
    entries, re := os.read_directory_by_path(path, -1, context.allocator)
    return expect(re == nil && len(entries) == 0, "Cancelled browser build left output behind.")
}
browser :: proc(requested: string) -> Error {
    when ODIN_OS != .Linux { return "Real browser acceptance currently runs on Linux only." }
    binary := absolute(requested) or_return
    chrome := find_chrome()
    if chrome == "" { return "A real Chrome/Chromium executable is required; set BUNDLR_SMOKE_CHROME." }
    base := temporary() or_return
    defer os.remove_all(base)
    overrides := make(map[string]string)
    overrides["BUNDLR_NO_BROWSER"], overrides["BUNDLR_CACHE_DIRECTORY"] = "1", b.join(base, "tools")
    if b.env("BUNDLR_PYTHON_CACHE_DIRECTORY") == "" { overrides["BUNDLR_PYTHON_CACHE_DIRECTORY"] = b.join(base, "python-cache") }
    app_log := b.join(base, "app.log")
    app := background([]string{binary}, app_log, environment(overrides)) or_return
    defer stop_background(&app)
    origin := ""
    started := time.tick_now()
    for origin == "" && time.tick_since(started) < 30*time.Second {
        if e := poll_background(&app); e != nil { return e }
        log := b.text(app_log) or_return
        if app.waited { return fmt.aprintf("Bundlr failed to start: %s", log) }
        if at := strings.index(log, "http://127.0.0.1:"); at >= 0 { origin = strings.fields(log[at:])[0] }
        time.sleep(30*time.Millisecond)
    }
    if origin == "" { return "Bundlr did not report its loopback URL." }
    origin = strings.trim_suffix(origin, "/")
    host := strings.trim_prefix(origin, "http://")
    page := http_request(host, "/") or_return
    token_at := strings.index(page.body, `const token = "`)
    if page.status != 200 || token_at < 0 { return "Browser page or session token is missing." }
    literal := page.body[token_at+len(`const token = "`):]
    token_end := strings.index(literal, `"`)
    if token_end < 0 { return "Browser session token is malformed." }
    token := literal[:token_end]
    for scenario in 0..<3 {
        value := token
        declared, supplied_origin := "", ""
        if scenario == 0 { value = "" }
        if scenario == 1 { declared = "attacker.example" }
        if scenario == 2 { supplied_origin = "https://attacker.example" }
        response := http_request(host, "/quit", "POST", token = value, origin = supplied_origin, host_header = declared) or_return
        if response.status != 403 { return "Browser authorization accepted an invalid Host, token or Origin." }
    }
    invalid := http_request(host, "/package", "POST", `{"source":"unpinned","applicationKind":"auto","targets":["linux-x86_64"]}`, token, origin) or_return
    if invalid.status != 400 { return "Browser accepted an invalid package request." }
    profile := b.join(base, "chrome")
    if e := b.mkdir(profile); e != nil { return e }
    chrome_log := b.join(base, "chrome.log")
    chrome_process := background([]string{chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", fmt.aprintf("--user-data-dir=%s", profile), origin}, chrome_log) or_return
    defer stop_background(&chrome_process)
    port := 0
    started = time.tick_now()
    for port == 0 && time.tick_since(started) < 30*time.Second {
        if e := poll_background(&chrome_process); e != nil { return e }
        if chrome_process.waited { return fmt.aprintf("Chrome exited: %s", b.text(chrome_log) or_return) }
        data, e := b.text(b.join(profile, "DevToolsActivePort"))
        if e == nil { port, _ = strconv.parse_int(strings.split_lines(data)[0]) }
        time.sleep(30*time.Millisecond)
    }
    if port == 0 { return "Chrome did not report its debugging port." }
    pages := http_request(fmt.aprintf("127.0.0.1:%d", port), "/json/list") or_return
    values, pe := json.parse(pages.body)
    if pe != .None { return "Invalid Chrome target listing." }
    targets, targets_ok := values.(json.Array)
    if !targets_ok { return "Chrome returned no target array." }
    websocket := ""
    for target in targets { object := json_object(target); if json_string(object["type"]) == "page" { websocket = json_string(object["webSocketDebuggerUrl"]); break } }
    if websocket == "" { return "Chrome returned no page debugger." }
    socket := websocket_connect(websocket) or_return
    defer net.close(socket.socket)
    if _, e := cdp_call(&socket, "Runtime.enable"); e != nil { return e }
    ready := false
    started = time.tick_now()
    for !ready && time.tick_since(started) < 30*time.Second {
        result := evaluate(&socket, `document.readyState === "complete" && !!document.querySelector("#form")`) or_return
        ready = result.(bool) or_else false
        if !ready { time.sleep(30*time.Millisecond) }
    }
    if !ready { return "Chrome did not finish loading the application form." }
    title := evaluate(&socket, "document.title") or_return
    if json_string(title) != "Bundlr" { return "Rendered browser page title changed." }
    if e := browser_themes(&socket); e != nil { return e }
    if e := client_stream_regression(&socket); e != nil { return e }
    if e := browser_fill(&socket, "#source", "unpinned"); e != nil { return e }
    if e := browser_click(&socket, "#package"); e != nil { return e }
    invalid_status := browser_status(&socket, "Error:") or_return
    if !strings.contains(invalid_status, "pinned") { return "Rendered form did not show validation failure." }
    output := b.join(base, "applications")
    for field, value in (map[string]string{"#source" = fmt.aprintf("black==%s", BLACK_VERSION), "#command" = "black", "#applicationName" = "BlackBrowser", "#outputDirectory" = output}) {
        if e := browser_fill(&socket, field, value); e != nil { return e }
    }
    if e := browser_click(&socket, "#package"); e != nil { return e }
    if e := browser_output(&socket); e != nil { return e }
    busy_body := b.json_text(struct { source, applicationKind: string, targets: []string }{fmt.aprintf("black==%s", BLACK_VERSION), "console", []string{"linux-x86_64"}})
    busy := http_request(host, "/package", "POST", busy_body, token, origin) or_return
    if busy.status != 409 { return "Browser admitted a concurrent build." }
    if e := browser_click(&socket, "#cancel"); e != nil { return e }
    cancelled := browser_status(&socket, "Error:") or_return
    if !strings.contains(strings.to_lower(cancelled), "cancel") && !strings.contains(strings.to_lower(cancelled), "abort") { return "Rendered browser cancellation was not reported." }
    if e := empty_output(output); e != nil { return e }
    if e := browser_click(&socket, "#package"); e != nil { return e }
    if _, e := browser_status(&socket, "Created "); e != nil { return e }
    if _, e := verify_recipient(b.join(output, "BlackBrowser-linux-x86_64.tar.gz"), b.join(base, "recipient"), "BlackBrowser", b.host_target()); e != nil { return e }
    shutdown := b.join(base, "shutdown")
    if e := browser_fill(&socket, "#outputDirectory", shutdown); e != nil { return e }
    if e := browser_click(&socket, "#package"); e != nil { return e }
    if e := browser_output(&socket); e != nil { return e }
    if e := browser_click(&socket, "#quit"); e != nil { return e }
    if _, e := browser_status(&socket, "Bundlr stopped."); e != nil { return e }
    if e := await_background(&app, 20*time.Second); e != nil { return e }
    if app.state.exit_code != 0 { return "Browser quit did not exit cleanly." }
    if e := empty_output(shutdown); e != nil { return e }
    fmt.println("Real Chrome validation, streaming, cancellation, concurrency, packaging, recipients and shutdown passed.")
    return nil
}
browser_themes :: proc(socket: ^WebSocket) -> Error {
    // Inspect real computed styles and use keyboard events on the actual toggle.
    media := struct { features: []struct { name, value: string } }{features = {{"prefers-color-scheme", "light"}}}
    if _, e := cdp_call(socket, "Emulation.setEmulatedMedia", media); e != nil { return e }
    defer { _, _ = cdp_call(socket, "Emulation.clearDeviceMetricsOverride") }
    for dark in ([2]bool{true, false}) {
        viewport := struct { width, height: int, deviceScaleFactor: f64, mobile: bool }{1280 if dark else 360, 900, 1, false}
        if _, e := cdp_call(socket, "Emulation.setDeviceMetricsOverride", viewport); e != nil { return e }
        expected := "dark" if dark else "light"
        value := evaluate(socket, `document.documentElement.dataset.theme`) or_return
        if json_string(value) != expected { return "Browser theme did not default to dark or toggle to light." }
        if _, e := evaluate(socket, `(() => {
const style = (selector, pseudo) => getComputedStyle(document.querySelector(selector), pseudo);
if (style('html').colorScheme !== document.documentElement.dataset.theme) throw Error('Native controls use the wrong colour scheme');
if (document.documentElement.scrollWidth > innerWidth) throw Error('Theme layout overflows the viewport');
const luminance = (color) => {
  const rgb = color.match(/[\d.]+/g).slice(0,3).map(value => {
    const channel = Number(value)/255;
    return channel <= .04045 ? channel/12.92 : ((channel+.055)/1.055)**2.4;
  });
  return .2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];
};
const contrast = (foreground, background, minimum) => {
  const a = luminance(foreground), b = luminance(background);
  if ((Math.max(a,b)+.05)/(Math.min(a,b)+.05) < minimum) throw Error('Insufficient theme contrast: '+foreground+' on '+background);
};
const page = style('body').backgroundColor;
for (const selector of ['body','h1','.subtitle','label','legend','#status']) contrast(style(selector).color, page, 4.5);
for (const selector of ['#source','#applicationKind','#theme','#package','#quit','#cancel','#output']) {
  const colors = style(selector);
  contrast(colors.color, colors.backgroundColor, 4.5);
  contrast(colors.borderTopColor, page, 3);
}
contrast(style('#source','::placeholder').color, style('#source').backgroundColor, 4.5);
contrast(style('fieldset').borderTopColor, page, 3);
const cancel = document.querySelector('#cancel');
cancel.disabled = false;
try { contrast(style('#cancel').color, style('#cancel').backgroundColor, 4.5); }
finally { cancel.disabled = true; }
const stderr = document.createElement('span');
stderr.className = 'stderr'; stderr.textContent = 'Error output';
document.querySelector('#output').append(stderr);
try { contrast(getComputedStyle(stderr).color, style('#output').backgroundColor, 4.5); }
finally { stderr.remove(); }
document.querySelector('#theme').focus();
return true;
})()`); e != nil { return e }
        for event_type in ([2]string{"keyDown", "keyUp"}) {
            params := struct { type, key, code: string, windowsVirtualKeyCode: int }{event_type, " ", "Space", 32}
            if _, e := cdp_call(socket, "Input.dispatchKeyEvent", params); e != nil { return e }
        }
        passed := evaluate(socket, `(() => {
const root = document.documentElement, toggle = document.querySelector('#theme');
const focused = getComputedStyle(toggle);
return toggle.matches(':focus-visible') && focused.outlineStyle !== 'none' && parseFloat(focused.outlineWidth) >= 3 && toggle.getAttribute('aria-pressed') === String(root.dataset.theme === 'dark') && localStorage.getItem('bundlr-theme') === root.dataset.theme;
})()`) or_return
        if good, ok := passed.(bool); !ok || !good { return "Theme toggle keyboard focus, accessible state or saved preference changed." }
    }
    fmt.println("Dark/light theme contrast and keyboard toggle checks passed.")
    return nil
}
client_stream_regression :: proc(socket: ^WebSocket) -> Error {
    page := b.PAGE
    begin := strings.index(page, `<script nonce="`)
    if begin < 0 { return "Cannot locate embedded browser script." }
    start := begin+strings.index(page[begin:], ">")+1
    end := strings.index(page[start:], "</script>")
    if end < 0 { return "Cannot locate embedded browser script end." }
    expression := b.replace(`(async () => {
const elements = new Map();
const element = (selector) => { if (!elements.has(selector)) elements.set(selector, {value:'', textContent:'', disabled:false, listeners:new Map(), addEventListener(name, listener) {this.listeners.set(name, listener)}}); return elements.get(selector); };
let controller, started = () => {};
const fakeFetch = async (route) => {
  if (route === '/cancel') return new Response(null, {status:204});
  if (route !== '/package') throw Error('Unexpected test route');
  return new Response(new ReadableStream({start(stream) {controller=stream; stream.enqueue(new TextEncoder().encode('{"type":"output","text":"partial')); started();}}));
};
const setup = (document, fetch, TextDecoder) => { /* BUNDLR_CLIENT_SCRIPT */ };
setup({querySelector:element, querySelectorAll:() => [{value:'linux-x86_64'}]}, fakeFetch, TextDecoder);
async function submit(cancel) {
  const ready = new Promise(resolve => {started=resolve});
  const completed = element('#form').listeners.get('submit')({preventDefault(){}});
  await ready;
  if (cancel) await element('#cancel').listeners.get('click')();
  controller.close(); await completed;
  return [element('#status').textContent, element('#package').disabled];
}
const first=await submit(true), second=await submit(false);
return first[0]==='Error: Cancelled by the user.' && first[1]===false && second[0]==='Error: Bundlr stopped before reporting a result.' && second[1]===false;
})()`, "/* BUNDLR_CLIENT_SCRIPT */", page[start:start+end])
    value := evaluate(socket, expression) or_return
    passed, ok := value.(bool)
    return expect(ok && passed, "Client cancellation of a partial frame or retry state regressed.")
}
