package acceptance

import "core:encoding/hex"
import "core:encoding/json"
import "core:mem/virtual"
import "core:testing"

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
    response, e := parse_response(transmute([]u8)response_text)
    testing.expect(t, e == nil && response.status == 200 && response.body == "{}")
    _, incomplete := parse_response(transmute([]u8)response_text[:len(response_text)-1])
    testing.expect(t, incomplete != nil)
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
