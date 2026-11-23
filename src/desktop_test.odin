package bundlr

import "core:mem/virtual"
import "core:testing"
import "core:strings"
import "core:encoding/json"
import "core:net"
import "core:sync"

@(test)
cancelled_progress_does_not_disconnect_client :: proc(t: ^testing.T) {
    job: Browser_Job
    job.build.user = &job
    job.build.cancelled = true
    // Cancellation must stop progress before touching even an invalid socket,
    // while leaving the connection available for the terminal error event.
    browser_output(&job.build, "stdout", "pending progress")
    testing.expect(t, !job.disconnected)
}

Test_Write_Mode :: enum { Partial, Cancel_Waiting, Cancel_Partial, Closed }
Test_Writer :: struct { build: ^Build, mode: Test_Write_Mode, calls: int, bytes: [dynamic]u8 }
partial_socket_write :: proc(socket: net.TCP_Socket, bytes: []u8) -> (int, net.TCP_Send_Error) {
    state := (^Test_Writer)(context.user_ptr)
    state.calls += 1
    switch state.mode {
    case .Cancel_Waiting:
        sync.atomic_store(&state.build.cancelled, true)
        return 0, .Would_Block
    case .Cancel_Partial:
        append(&state.bytes, bytes[0])
        sync.atomic_store(&state.build.cancelled, true)
        return 1, .Would_Block
    case .Closed:
        return 0, .Connection_Closed
    case .Partial:
        if state.calls == 1 { return 0, .Would_Block }
        if state.calls == 2 { return 0, .Interrupted }
        count := min(3, len(bytes))
        append(&state.bytes, ..bytes[:count])
        return count, .None
    }
    unreachable()
}

@(test)
stream_writes_handle_backpressure_and_cancellation :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    state: Test_Writer
    context.user_ptr = &state

    // Partial writes, temporary backpressure and interruptions must preserve data.
    result := send_socket({}, "complete message", write = partial_socket_write)
    testing.expect(t, result == .Sent && string(state.bytes[:]) == "complete message")

    job: Browser_Job
    state = Test_Writer{build = &job.build, mode = .Cancel_Waiting}
    send_event(&job, Output_Event{"output", "stdout", "pending"}, progress = true, write = partial_socket_write)
    testing.expect(t, state.calls == 1 && !job.disconnected && job.build.cancelled)
    // No frame was started, so the terminal cancellation event is still valid.
    state.mode = .Partial
    send_event(&job, Error_Event{"error", "Cancelled by the user."}, write = partial_socket_write)
    terminal: Error_Event
    testing.expect(t, json.unmarshal(state.bytes[:], &terminal) == nil)
    testing.expect(t, terminal.type == "error" && terminal.message == "Cancelled by the user.")

    job = {}
    state = Test_Writer{build = &job.build, mode = .Cancel_Partial}
    send_event(&job, Output_Event{"output", "stdout", "partial"}, progress = true, write = partial_socket_write)
    testing.expect(t, state.calls == 1 && job.disconnected && job.build.cancelled)
    send_event(&job, Error_Event{"error", "Cancelled by the user."}, write = partial_socket_write)
    testing.expect(t, state.calls == 1 && len(state.bytes) == 1, "Do not append an event to a truncated JSON frame.")

    job = {}
    state = Test_Writer{build = &job.build, mode = .Closed}
    send_event(&job, Output_Event{"output", "stdout", "closed"}, progress = true, write = partial_socket_write)
    testing.expect(t, job.disconnected && job.build.cancelled)
}

@(test)
terminal_write_deadline_is_not_extended_by_partial_progress :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    state: Test_Writer
    context.user_ptr = &state
    // The writer permits three bytes per retry, keeping progress continuous.
    // A terminal event has no cancellation token, so its absolute send bound
    // must still end the write rather than restarting on every partial send.
    message := strings.repeat("x", 32768)
    result := send_socket({}, message, write = partial_socket_write)
    testing.expect(t, result == .Disconnected)
    testing.expect(t, len(state.bytes) > 0 && len(state.bytes) < len(message))
}

@(test)
http_framing :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    r, done, e := parse_http("POST /package HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 2\r\n\r\n{}")
    testing.expect(t, e == nil && done && r.body == "{}")
    _, incomplete, ie := parse_http("POST /package HTTP/1.1\r\nContent-Length: 2\r\n\r\n{")
    testing.expect(t, ie == nil && !incomplete)
    for input in ([]string{
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra",
    }) { _, _, failure := parse_http(input); testing.expect(t, failure != nil) }
}
@(test)
http_auth_and_request_types :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    r := Http_Request{method = "POST", host = "127.0.0.1:1", token = "secret", origin = "http://127.0.0.1:1"}
    testing.expect(t, authorized(r, r.host, "secret"))
    r.origin = "https://attacker.invalid"
    testing.expect(t, !authorized(r, r.host, "secret"))
    r.origin = ""
    testing.expect(t, authorized(r, r.host, "secret"))
    testing.expect(t, !authorized(r, "localhost:1", "secret"))
    testing.expect(t, !authorized(r, r.host, "wrong"))
    for data in ([]string{`null`, `[]`, `{"source":3}`, `{"source":"a==1","applicationKind":"auto","targets":["bad"]}`, `{"source":"a==1","source":"b==1"}`}) {
        _, e := decode_request(data); testing.expect(t, e != nil)
    }
    valid, e := decode_request(`{"source":"a==1","applicationKind":"auto","targets":["linux-x86_64"]}`)
    testing.expect(t, e == nil && valid.applicationName == "a")
    html := page("example_nonce")
    testing.expect(t, !strings.contains(html, "@@") && strings.contains(html, `nonce="example_nonce"`))
}

@(test)
streamed_utf8_preserves_split_characters :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    d: Utf8_Stream
    testing.expect(t, decode_output(&d, "\xc3", false) == "")
    testing.expect(t, decode_output(&d, "\xa9\xe6\xbc", false) == "é")
    testing.expect(t, decode_output(&d, "\xa2字", false) == "漢字")
    testing.expect(t, decode_output(&d, "\xff", false) == "�")
    testing.expect(t, decode_output(&d, "\xe6", false) == "")
    testing.expect(t, decode_output(&d, "", true) == "�")
}
