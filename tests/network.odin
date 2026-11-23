package acceptance

import b "../src"
import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

Http_Response :: struct { status: int, headers, body: string }
Socket_Reader :: #type proc(socket: net.TCP_Socket, bytes: []u8) -> (int, net.TCP_Recv_Error)
dial_loopback :: proc(host: string) -> (socket: net.TCP_Socket, failure: Error) {
    if !strings.has_prefix(host, "127.0.0.1:") { return {}, "Acceptance connections must stay on loopback." }
    result, e := net.dial_tcp_from_hostname_and_port_string(host)
    if e != nil { return {}, fmt.aprintf("Cannot connect to loopback: %v", e) }
    if net.set_blocking(result, false) != .None { net.close(result); return {}, "Cannot configure acceptance socket." }
    return result, nil
}
send_bytes :: proc(socket: net.TCP_Socket, bytes: []u8) -> Error {
    if b.send_socket(socket, string(bytes)) != .Sent { return "Loopback connection closed while sending." }
    return nil
}
receive_more :: proc(socket: net.TCP_Socket, bytes: ^[dynamic]u8, started: time.Tick, timeout: time.Duration, read: Socket_Reader = net.recv_tcp) -> (closed: bool, failure: Error) {
    for time.tick_since(started) < timeout {
        buffer: [8192]u8
        n, e := read(socket, buffer[:])
        if n > 0 {
            if len(bytes^)+n > 16*1024*1024 { return false, "Acceptance response exceeds its size bound." }
            append(bytes, ..buffer[:n]); return false, nil
        }
        if e == .None && n == 0 { return true, nil }
        if e != .Would_Block && e != .Interrupted { return false, fmt.aprintf("Loopback receive failed: %v", e) }
        time.sleep(time.Millisecond)
    }
    return false, "Loopback response timed out."
}
header_value :: proc(headers, key: string) -> string {
    for line in strings.split_lines(headers) {
        at := strings.index(line, ":")
        if at > 0 && strings.to_lower(line[:at]) == key { return b.trim(line[at+1:]) }
    }
    return ""
}
parse_response :: proc(bytes: []u8, closed := true) -> (response: Http_Response, complete: bool, failure: Error) {
    split := strings.index(string(bytes), "\r\n\r\n")
    if split < 0 {
        if closed { return response, false, "Incomplete HTTP response headers." }
        return response, false, nil
    }
    response.headers, response.body = string(bytes[:split]), string(bytes[split+4:])
    lines := strings.split(response.headers, "\r\n")
    first := strings.fields(lines[0])
    if len(first) < 2 || first[0] != "HTTP/1.1" && first[0] != "HTTP/1.0" { return response, false, "Malformed HTTP response." }
    status, ok := strconv.parse_int(first[1])
    if !ok || status < 200 || status > 599 { return response, false, "Unsupported HTTP response status." }
    response.status = status
    length := -1
    for line in lines[1:] {
        colon := strings.index(line, ":")
        if colon < 1 { return response, false, "Malformed HTTP response header." }
        key, value := strings.to_lower(line[:colon]), b.trim(line[colon+1:])
        switch key {
        case "transfer-encoding": return response, false, "Unexpected encoded HTTP response."
        case "content-length":
            size, good := strconv.parse_int(value)
            if length >= 0 || !good || !b.regex_match(`^[0-9]+$`, value) || size > 16*1024*1024 { return response, false, "Invalid HTTP response length." }
            length = size
        }
    }
    if status == 204 || status == 304 { length = 0 }
    if length < 0 { return response, closed, nil }
    if len(response.body) > length || closed && len(response.body) < length { return response, false, "HTTP response length mismatch." }
    return response, len(response.body) == length, nil
}
http_request :: proc(host, route: string, method := "GET", body := "", token := "", origin := "", host_header := "") -> (response: Http_Response, failure: Error) {
    socket := dial_loopback(host) or_return
    defer net.close(socket)
    declared := host if host_header == "" else host_header
    extra := ""
    if token != "" { extra = fmt.aprintf("%sX-Bundlr-Token: %s\r\n", extra, token) }
    if origin != "" { extra = fmt.aprintf("%sOrigin: %s\r\n", extra, origin) }
    request := fmt.aprintf("%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n%s\r\n%s", method, route, declared, len(body), extra, body)
    if e := send_bytes(socket, transmute([]u8)request); e != nil { return response, fmt.aprintf("%s %s%s: %v", method, host, route, e) }
    response, failure = receive_http_response(socket)
    if failure != nil { return response, fmt.aprintf("%s %s%s: %v", method, host, route, failure) }
    return response, nil
}
receive_http_response :: proc(socket: net.TCP_Socket, timeout := 10*time.Second, read: Socket_Reader = net.recv_tcp) -> (response: Http_Response, failure: Error) {
    bytes: [dynamic]u8
    started := time.tick_now()
    closed, complete := false, false
    for {
        response, complete, failure = parse_response(bytes[:], closed)
        if failure != nil { return response, failure }
        if complete { return response, nil }
        closed, failure = receive_more(socket, &bytes, started, timeout, read)
        if failure != nil { return response, failure }
    }
}
WebSocket :: struct { socket: net.TCP_Socket, input: [dynamic]u8, consumed, next_id: int }
websocket_connect :: proc(url: string) -> (socket: WebSocket, failure: Error) {
    scheme, host, path, _, _ := net.split_url(url)
    if scheme != "ws" { return socket, "Chrome returned an unsupported debugging URL." }
    socket.socket = dial_loopback(host) or_return
    ok := false
    defer { if !ok { net.close(socket.socket) } }
    nonce: [16]u8
    crypto.rand_bytes(nonce[:])
    key := base64.encode(nonce[:])
    request := fmt.aprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n\r\n", path, host, key)
    if e := send_bytes(socket.socket, transmute([]u8)request); e != nil { return socket, e }
    started := time.tick_now()
    for strings.index(string(socket.input[:]), "\r\n\r\n") < 0 {
        closed, e := receive_more(socket.socket, &socket.input, started, 5*time.Second)
        if e != nil { return socket, fmt.aprintf("Chrome WebSocket handshake: %v", e) }
        if closed { return socket, "Chrome closed the WebSocket handshake." }
    }
    end := strings.index(string(socket.input[:]), "\r\n\r\n")
    headers := string(socket.input[:end])
    if !strings.has_prefix(headers, "HTTP/1.1 101 ") || header_value(headers, "sec-websocket-accept") != websocket_accept(key) { return socket, "Invalid Chrome WebSocket handshake." }
    socket.consumed = end+4
    ok = true
    return socket, nil
}
websocket_accept :: proc(key: string) -> string {
    // SHA-1 is mandated by RFC 6455 for this protocol handshake only.
    material := fmt.aprintf("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key)
    state: sha1.Context
    digest: [20]u8
    sha1.init(&state)
    sha1.update(&state, transmute([]u8)material)
    sha1.final(&state, digest[:])
    return base64.encode(digest[:])
}
websocket_packet :: proc(opcode: u8, payload: []u8, mask: [4]u8) -> []u8 {
    packet: [dynamic]u8
    append(&packet, u8(0x80)|opcode)
    if len(payload) < 126 { append(&packet, u8(0x80)|u8(len(payload))) }
    else if len(payload) <= 65535 { append(&packet, u8(0xfe), u8(len(payload)>>8), u8(len(payload))) }
    else {
        append(&packet, u8(0xff))
        for shift := 56; shift >= 0; shift -= 8 { append(&packet, u8(u64(len(payload))>>u64(shift))) }
    }
    for byte in mask { append(&packet, byte) }
    for byte, i in payload { append(&packet, byte~mask[i%4]) }
    return packet[:]
}
websocket_send :: proc(socket: ^WebSocket, opcode: u8, text: string) -> Error {
    mask: [4]u8
    crypto.rand_bytes(mask[:])
    return send_bytes(socket.socket, websocket_packet(opcode, transmute([]u8)text, mask))
}
websocket_frame :: proc(bytes: []u8) -> (opcode: u8, final: bool, payload: []u8, consumed: int, complete: bool, failure: Error) {
    if len(bytes) < 2 { return }
    opcode, final = bytes[0]&15, bytes[0]&128 != 0
    if bytes[0]&0x70 != 0 || bytes[1]&128 != 0 { failure = "Unsupported WebSocket flags or server mask."; return }
    size, header := u64(bytes[1]&127), 2
    if size == 126 {
        if len(bytes) < 4 { return }
        size, header = u64(bytes[2])<<8|u64(bytes[3]), 4
    } else if size == 127 {
        if len(bytes) < 10 { return }
        size, header = 0, 10
        for byte in bytes[2:10] { size = size<<8|u64(byte) }
    }
    if size > 16*1024*1024 || opcode >= 8 && (!final || size > 125) { failure = "Invalid WebSocket frame size."; return }
    if u64(len(bytes)-header) < size { return }
    consumed, complete = header+int(size), true
    payload = bytes[header:consumed]
    return
}
websocket_message :: proc(socket: ^WebSocket, started: time.Tick) -> (value: string, failure: Error) {
    message: [dynamic]u8
    fragmented := false
    for {
        opcode, final, payload, consumed, complete, e := websocket_frame(socket.input[socket.consumed:])
        if e != nil { return "", e }
        if complete {
            socket.consumed += consumed
            switch opcode {
            case 8: return "", "Chrome closed its debugging connection."
            case 9: if ping_error := websocket_send(socket, 10, string(payload)); ping_error != nil { return "", ping_error }
            case 10:
            case 0, 1:
                if opcode == 0 && !fragmented || opcode == 1 && fragmented { return "", "Invalid WebSocket message fragmentation." }
                append(&message, ..payload)
                if len(message) > 16*1024*1024 { return "", "Chrome debugging message exceeds its bound." }
                fragmented = !final
                if final { return string(message[:]), nil }
            case: return "", "Unexpected Chrome WebSocket opcode."
            }
        } else {
            if socket.consumed > 0 {
                count := copy(socket.input[:], socket.input[socket.consumed:])
                resize(&socket.input, count)
                socket.consumed = 0
            }
            closed, re := receive_more(socket.socket, &socket.input, started, 30*time.Second)
            if re != nil { return "", re }
            if closed { return "", "Chrome disconnected from debugging." }
        }
    }
}
json_object :: proc(value: json.Value) -> json.Object { return value.(json.Object) or_else nil }
json_string :: proc(value: json.Value) -> string { return value.(string) or_else "" }
cdp_request :: proc(id: int, method: string, params: any) -> (value: string, failure: Error) {
    // The pinned JSON encoder accepts a dynamic top-level value but does not
    // encode an `any` field inside a struct. Encode protocol parameters first.
    encoded, e := json.marshal(params)
    if e != nil { return "", "Cannot encode Chrome debugging parameters." }
    return fmt.aprintf(`%s"id":%d,"method":%s,"params":%s%s`, "{", id, b.json_text(method), string(encoded), "}"), nil
}
cdp_call :: proc(socket: ^WebSocket, method: string, params: any = struct{}{}) -> (value: json.Object, failure: Error) {
    socket.next_id += 1
    id := socket.next_id
    request := cdp_request(id, method, params) or_return
    if e := websocket_send(socket, 1, request); e != nil { return nil, fmt.aprintf("Chrome %s: %v", method, e) }
    started := time.tick_now()
    for {
        text, e := websocket_message(socket, started)
        if e != nil { return nil, fmt.aprintf("Chrome %s: %v", method, e) }
        response, pe := json.parse(text, parse_integers = true)
        if pe != .None { return nil, "Malformed Chrome debugging response." }
        object := json_object(response)
        if json_string(object["method"]) == "Runtime.exceptionThrown" { return nil, fmt.aprintf("Browser JavaScript exception: %s", text) }
        if response_id, ok := object["id"].(i64); ok && response_id == i64(id) {
            if _, failed := object["error"]; failed { return nil, fmt.aprintf("Chrome debugging error: %s", text) }
            return json_object(object["result"]), nil
        }
    }
}
evaluate :: proc(socket: ^WebSocket, expression: string) -> (value: json.Value, failure: Error) {
    params := struct { expression: string, returnByValue, awaitPromise: bool }{expression, true, true}
    result := cdp_call(socket, "Runtime.evaluate", params) or_return
    if _, exists := result["exceptionDetails"]; exists { return {}, fmt.aprintf("Browser evaluation failed: %s", b.json_text(result)) }
    return json_object(result["result"])["value"], nil
}
