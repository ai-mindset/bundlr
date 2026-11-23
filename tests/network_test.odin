package acceptance

import "core:encoding/hex"
import "core:encoding/json"
import "core:mem/virtual"
import "core:net"
import "core:testing"
import "core:time"

@(test)
websocket_rfc_handshake_masking_and_frame_guards :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    testing.expect_value(t, websocket_accept("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    hello := "Hello"
    packet := websocket_packet(1, transmute([]u8)hello, {0x37, 0xfa, 0x21, 0x3d})
    testing.expect_value(t, string(hex.encode(packet)), "818537fa213d7f9f4d5158")
    server := []u8{0x81, 5, 'H', 'e', 'l', 'l', 'o'}
    for i in 0..<len(server) {
        _, _, _, _, complete, e := websocket_frame(server[:i])
        testing.expect(t, !complete && e == nil)
    }
    opcode, final, payload, consumed, complete, e := websocket_frame(server)
    testing.expect(t, e == nil && complete && final && opcode == 1 && string(payload) == "Hello" && consumed == len(server))
    _, _, _, _, _, masked := websocket_frame(packet)
    testing.expect(t, masked != nil)
    _, _, _, _, _, oversized := websocket_frame([]u8{0x81, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
    testing.expect(t, oversized != nil)
    _, _, _, _, _, fragmented_control := websocket_frame([]u8{0x09, 0})
    testing.expect(t, fragmented_control != nil)
}
@(test)
http_response_framing_rejects_incomplete_data :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    response_text := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
    response, complete, e := parse_response(transmute([]u8)response_text)
    testing.expect(t, e == nil && complete && response.status == 200 && response.body == "{}")
    _, _, incomplete := parse_response(transmute([]u8)response_text[:len(response_text)-1])
    testing.expect(t, incomplete != nil)
    for size in 0..<len(response_text) {
        _, partial_complete, partial_error := parse_response(transmute([]u8)response_text[:size], false)
        testing.expect(t, !partial_complete && partial_error == nil)
    }
    for malformed in ([]string{
        "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: \r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nextra",
    }) {
        _, _, malformed_error := parse_response(transmute([]u8)malformed, false)
        testing.expect(t, malformed_error != nil)
    }
    eof_text := "HTTP/1.1 200 OK\r\n\r\nbody until EOF"
    _, awaiting_eof, eof_error := parse_response(transmute([]u8)eof_text, false)
    testing.expect(t, !awaiting_eof && eof_error == nil)
}
@(test)
cdp_evaluation_parameters_are_encoded :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    expression := "document.querySelector(\"#form\")\n"
    params := struct { expression: string, returnByValue, awaitPromise: bool }{expression, true, true}
    request, e := cdp_request(7, "Runtime.evaluate", params)
    if !testing.expect(t, e == nil) { return }
    decoded: struct { id: int, method: string, params: struct { expression: string, returnByValue, awaitPromise: bool } }
    if !testing.expect(t, json.unmarshal(transmute([]u8)request, &decoded) == nil) { return }
    testing.expect(t, decoded.id == 7 && decoded.method == "Runtime.evaluate")
    testing.expect(t, decoded.params.expression == expression && decoded.params.returnByValue && decoded.params.awaitPromise)
    empty, empty_error := cdp_request(8, "Runtime.enable", struct{}{})
    testing.expect(t, empty_error == nil && json.unmarshal(transmute([]u8)empty, &decoded) == nil)
}

Http_Test_Stream :: struct { data: string, offset, chunk_size: int, closed: bool }
read_http_test_stream :: proc(socket: net.TCP_Socket, bytes: []u8) -> (int, net.TCP_Recv_Error) {
    stream := (^Http_Test_Stream)(context.user_ptr)
    remaining := stream.data[stream.offset:]
    if len(remaining) == 0 { return 0, .None if stream.closed else .Would_Block }
    count := min(len(remaining), len(bytes), stream.chunk_size)
    copy(bytes[:count], transmute([]u8)remaining[:count])
    stream.offset += count
    return count, .None
}
@(test)
http_response_finishes_without_peer_close :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    for chunk_size in ([2]int{1, 8192}) {
        stream := Http_Test_Stream{data = "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\né漢字", chunk_size = chunk_size}
        context.user_ptr = &stream
        // After the full body, the peer stays open and every read would block.
        response, e := receive_http_response({}, time.Second, read_http_test_stream)
        if !testing.expect(t, e == nil) { continue }
        testing.expect(t, response.status == 200 && response.body == "é漢字")
    }
}
@(test)
http_response_checks_eof_and_bodyless_statuses :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    for example in ([]struct { data, body: string, closed, succeeds: bool }{
        {"HTTP/1.1 200 OK\r\n\r\nbody until EOF", "body until EOF", true, true},
        {"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", "", false, true},
        {"HTTP/1.1 204 No Content\r\n\r\n", "", false, true},
        {"HTTP/1.1 304 Not Modified\r\n\r\n", "", false, true},
        {"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{", "", true, false},
        {"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n", "", true, false},
    }) {
        stream := Http_Test_Stream{data = example.data, chunk_size = 8192, closed = example.closed}
        context.user_ptr = &stream
        response, e := receive_http_response({}, time.Second, read_http_test_stream)
        testing.expect(t, (e == nil) == example.succeeds)
        if e == nil { testing.expect(t, response.body == example.body) }
    }
}
