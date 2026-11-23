package bundlr

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

PAGE :: #load("desktop.html", string)
Http_Request :: struct { method, route, host, origin, token, body: string }
// Returns complete only after the bounded, unambiguous Content-Length body.
parse_http :: proc(data: string) -> (request: Http_Request, complete: bool, failure: Error) {
    end := strings.index(data, "\r\n\r\n")
    if end < 0 {
        if len(data) > 16384 { return {}, false, "HTTP headers too large." }
        return {}, false, nil
    }
    if end > 16384 { return {}, false, "HTTP headers too large." }
    lines := strings.split(data[:end], "\r\n")
    first := strings.split(lines[0], " ")
    if len(first) != 3 || first[2] != "HTTP/1.1" || !strings.has_prefix(first[1], "/") { return {}, false, "Invalid HTTP request." }
    request.method, request.route = first[0], first[1]
    length := 0
    seen: map[string]bool
    for line in lines[1:] {
        colon := strings.index(line, ":")
        if colon < 1 || line[0] == ' ' || line[0] == '\t' { return {}, false, "Invalid HTTP header." }
        key, value := strings.to_lower(line[:colon]), trim(line[colon+1:])
        if seen[key] { return {}, false, "Duplicate HTTP header." }
        seen[key] = true
        switch key {
        case "host": request.host = value
        case "origin": request.origin = value
        case "x-bundlr-token": request.token = value
        case "transfer-encoding": return {}, false, "Transfer encoding is not supported."
        case "content-length":
            if !regex_match(`^[0-9]+$`, value) { return {}, false, "Invalid Content-Length." }
            n, ok := strconv.parse_int(value)
            if !ok || n < 0 || n > 65536 { return {}, false, "Request too large." }
            length = n
        }
    }
    body := data[end+4:]
    if len(body) < length { return request, false, nil }
    if len(body) > length { return {}, false, "HTTP pipelining is not supported." }
    request.body = body
    return request, true, nil
}
authorized :: proc(r: Http_Request, host, token: string) -> bool {
    return r.host == host && r.method == "POST" && r.token == token && (r.origin == "" || r.origin == fmt.aprintf("http://%s", host))
}
decode_request :: proc(data: string) -> (r: Request, failure: Error) {
    if json.unmarshal(transmute([]u8)data, &r) != nil { return r, "Invalid package request." }
    r.source = parse_source(r.source) or_return
    if r.applicationName == "" { r.applicationName = infer_name(r.source) }
    if r.python == "" { r.python = "3.12" }
    if r.outputDirectory == "" { r.outputDirectory = "dist" }
    return r, validate(r)
}
page :: proc(token: string) -> string {
    html := replace(PAGE, "@@TOKEN@@", token)
    html = replace(html, "@@TARGET@@", host_target())
    html = replace(html, "@@VERSION@@", VERSION)
    for target in TARGETS { html = replace(html, fmt.aprintf("@@%s@@", target), "checked" if target == host_target() else "") }
    return html
}
Send_Result :: enum { Sent, Cancelled, Disconnected }
Socket_Writer :: #type proc(socket: net.TCP_Socket, bytes: []u8) -> (int, net.TCP_Send_Error)
send_socket :: proc(socket: net.TCP_Socket, data: string, build: ^Build = nil, write: Socket_Writer = net.send_tcp) -> Send_Result {
    remaining := transmute([]u8)data
    started := time.tick_now()
    for len(remaining) > 0 {
        if check_cancel(build) != nil {
            // A partial NDJSON frame cannot be followed by another event.
            return .Cancelled if len(remaining) == len(data) else .Disconnected
        }
        // This is an absolute bound, including terminal events after cancellation.
        if time.tick_since(started) >= 5*time.Second { return .Disconnected }
        n, e := write(socket, remaining)
        remaining = remaining[n:]
        if e != .None && e != .Would_Block && e != .Interrupted { return .Disconnected }
        if len(remaining) > 0 { time.sleep(time.Millisecond) }
    }
    return .Sent
}
respond :: proc(socket: net.TCP_Socket, status: int, body: string, content_type := "text/plain; charset=utf-8", extra := "") {
    _ = send_socket(socket, fmt.aprintf("HTTP/1.1 %d Result\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s", status, content_type, len(body), extra, body))
}
Browser_Job :: struct {
    build: Build,
    socket: net.TCP_Socket,
    request: string,
    done, disconnected: bool,
    worker: ^thread.Thread,
    decoders: [2]Utf8_Stream,
}
Output_Event :: struct { type: string, stream, text: string }
Error_Event :: struct { type, message: string }
Done_Event :: struct { type: string, results: []Package_Result }
send_event :: proc(job: ^Browser_Job, event: any, progress := false, write: Socket_Writer = net.send_tcp) {
    if sync.atomic_load(&job.disconnected) { return }
    build := &job.build if progress else nil
    if send_socket(job.socket, fmt.aprintf("%s\n", json_text(event)), build, write) == .Disconnected {
        sync.atomic_store(&job.disconnected, true)
        sync.atomic_store(&job.build.cancelled, true)
    }
}
browser_output :: proc(b: ^Build, stream, text: string) {
    // A nested arena keeps long-running streamed builds from retaining every
    // marshalled progress event until completion.
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil { sync.atomic_store(&b.cancelled, true); return }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    job := (^Browser_Job)(b.user)
    i := 0 if stream == "stdout" else 1
    decoded := decode_output(&job.decoders[i], text, false)
    if len(decoded) > 0 { send_event(job, Output_Event{"output", stream, decoded}, progress = true) }
}
browser_build :: proc(t: ^thread.Thread) {
    job := (^Browser_Job)(t.data)
    defer sync.atomic_store(&job.done, true)
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil { return }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    r, e := decode_request(job.request)
    if e != nil { send_event(job, Error_Event{"error", fmt.aprintf("%v", e)}); return }
    results, err := package_targets(&job.build, r)
    for stream, i in ([2]string{"stdout", "stderr"}) {
        decoded := decode_output(&job.decoders[i], "", true)
        if decoded != "" { send_event(job, Output_Event{"output", stream, decoded}, progress = true) }
    }
    if err != nil { send_event(job, Error_Event{"error", fmt.aprintf("%v", err)}) }
    else { send_event(job, Done_Event{"done", results}) }
}
Connection :: struct { socket: net.TCP_Socket, data: [dynamic]u8, opened: time.Tick, used: bool }
start_desktop :: proc() -> Error {
    listener, le := net.listen_tcp({net.IP4_Address{127, 0, 0, 1}, 0})
    if le != nil { return fmt.aprintf("Cannot bind loopback browser server: %v", le) }
    defer net.close(listener)
    if net.set_blocking(listener, false) != .None { return "Cannot configure browser server." }
    ep, be := net.bound_endpoint(listener)
    if be != .None { return "Cannot discover browser server port." }
    host := fmt.aprintf("127.0.0.1:%d", ep.port)
    random: [32]u8
    crypto.rand_bytes(random[:])
    token := string(hex.encode(random[:]))
    fmt.printf("Bundlr browser interface: http://%s/\n", host)
    if env("BUNDLR_NO_BROWSER") != "1" {
        opener := "xdg-open"
        when ODIN_OS == .Windows { opener = "explorer.exe" }
        else when ODIN_OS == .Darwin { opener = "open" }
        p, oe := os.process_start({command = []string{opener, fmt.aprintf("http://%s/", host)}})
        if oe == nil { reap_browser_async(p) }
    }
    connections: [32]Connection
    defer for c in connections { if c.used { net.close(c.socket); delete(c.data) } }
    job: ^Browser_Job
    stopping := false
    defer {
        if job != nil {
            sync.atomic_store(&job.build.cancelled, true)
            thread.join(job.worker)
            thread.destroy(job.worker)
            net.close(job.socket)
            delete(job.request, os.heap_allocator())
            free(job, os.heap_allocator())
        }
    }
    for {
        if was_signalled() { stopping = true; if job != nil { sync.atomic_store(&job.build.cancelled, true) } }
        if job != nil {
            if sync.atomic_load(&job.done) {
                thread.join(job.worker)
                thread.destroy(job.worker)
                net.close(job.socket)
                delete(job.request, os.heap_allocator())
                free(job, os.heap_allocator())
                job = nil
            } else {
                buf: [1]u8
                n, re := net.recv_tcp(job.socket, buf[:])
                if re == .None && n == 0 || re != .None && re != .Would_Block && re != .Interrupted {
                    sync.atomic_store(&job.disconnected, true)
                    sync.atomic_store(&job.build.cancelled, true)
                }
            }
        }
        if stopping && job == nil { break }
        socket, _, ae := net.accept_tcp(listener)
        if ae == .None {
            if net.set_blocking(socket, false) != .None { net.close(socket) }
            else {
                added := false
                for &c in connections { if !c.used { c = Connection{socket = socket, opened = time.tick_now(), used = true}; c.data.allocator = os.heap_allocator(); added = true; break } }
                if !added { net.close(socket) }
            }
        } else if ae != .Would_Block && ae != .Interrupted { return "Browser accept failed." }
        for &c in connections {
            if !c.used { continue }
            buf: [8192]u8
            n, re := net.recv_tcp(c.socket, buf[:])
            close := false
            if re == .None && n == 0 || re != .None && re != .Would_Block && re != .Interrupted || time.tick_since(c.opened) > 10*time.Second {
                close = true
            } else if n > 0 {
                append(&c.data, ..buf[:n])
                arena: virtual.Arena
                if virtual.arena_init_growing(&arena) != nil { return "Cannot allocate HTTP request memory." }
                previous := context.allocator
                context.allocator = virtual.arena_allocator(&arena)
                r, complete, err := parse_http(string(c.data[:]))
                if err != nil { respond(c.socket, 400, fmt.aprintf("%v", err)); close = true }
                else if complete {
                    close = true
                    if r.host != host { respond(c.socket, 403, "Forbidden") }
                    else if r.method == "GET" && r.route == "/" {
                        respond(c.socket, 200, page(token), "text/html; charset=utf-8", fmt.aprintf("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-%s'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'\r\n", token))
                    } else if !authorized(r, host, token) { respond(c.socket, 403, "Forbidden") }
                    else {
                        switch r.route {
                        case "/cancel": if job != nil { sync.atomic_store(&job.build.cancelled, true) }; respond(c.socket, 204, "")
                        case "/quit": stopping = true; if job != nil { sync.atomic_store(&job.build.cancelled, true) }; respond(c.socket, 204, "")
                        case "/package":
                            request, ve := decode_request(r.body)
                            if ve != nil { respond(c.socket, 400, fmt.aprintf("%v", ve)) }
                            else if stopping || job != nil { respond(c.socket, 409, "A build is already running or Bundlr is stopping.") }
                            else if send_socket(c.socket, "HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Type: application/x-ndjson; charset=utf-8\r\n\r\n") == .Sent {
                                job = new(Browser_Job, os.heap_allocator())
                                job.socket = c.socket
                                job.request = strings.clone(json_text(request), os.heap_allocator())
                                job.build.output = browser_output
                                job.build.user = job
                                job.worker = create_browser_worker()
                                job.worker.data = job
                                thread.start(job.worker)
                                c.used = false // The active job owns the socket now.
                            }
                        case: respond(c.socket, 404, "Not found")
                        }
                    }
                }
                context.allocator = previous
                virtual.arena_destroy(&arena)
            }
            if close { if c.used { net.close(c.socket) }; delete(c.data); c = {} }
        }
        time.sleep(5*time.Millisecond)
    }
    return nil
}

create_browser_worker :: proc() -> ^thread.Thread {
    context.allocator = os.heap_allocator()
    return thread.create(browser_build)
}

Utf8_Stream :: struct { tail: [4]u8, length: int }
decode_output :: proc(d: ^Utf8_Stream, input: string, final: bool) -> string {
    combined := make([]u8, d.length+len(input))
    copy(combined, d.tail[:d.length])
    copy(combined[d.length:], transmute([]u8)input)
    d.length = 0
    output: [dynamic]u8
    at := 0
    for at < len(combined) {
        if !final && !utf8.full_rune(combined[at:]) {
            d.length = copy(d.tail[:], combined[at:])
            break
        }
        r, width := utf8.decode_rune(combined[at:])
        encoded, size := utf8.encode_rune(r)
        append(&output, ..encoded[:size])
        at += width
    }
    return string(output[:])
}

// Desktop openers may stay alive for the lifetime of the browser. Reap them
// independently so opening the page cannot block request handling.
reap_browser_async :: proc(process: os.Process) {
    context.allocator = os.heap_allocator()
    saved := new(os.Process)
    saved^ = process
    _ = thread.create_and_start_with_data(saved, proc(data: rawptr) {
        process := (^os.Process)(data)
        _, _ = os.process_wait(process^)
        free(process, os.heap_allocator())
    }, self_cleanup = true)
}
