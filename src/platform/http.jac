"""A loopback HTTP transport: libuv owns sockets and llhttp parses requests."""
import from src.platform.ffi_uv {
    Buffer,
    make_buffer,
    calloc,
    free,
    checked,
    new_handle,
    uv_default_loop,
    uv_tcp_init,
    uv_ip4_addr,
    uv_tcp_bind,
    uv_tcp_getsockname,
    uv_listen,
    uv_accept,
    uv_read_start,
    uv_read_stop,
    uv_write,
    uv_close,
    uv_is_closing,
    uv_req_size,
    close_handle
}

import from .llhttp {
    obj Parser {
        has index: i32,
            span_pos: ptr,
            span_cb: ptr,
            error: i32,
            reason: ptr,
            error_pos: ptr,
            data: ptr,
            current: ptr,
            content_length: u64,
            kind: u8,
            method: u8,
            major: u8,
            minor: u8,
            header_state: u8,
            lenient_flags: u16,
            upgrade: u8,
            finish: u8,
            flags: u16,
            status: u16,
            initial_complete: u8,
            settings: ptr;
    }  obj Settings {
        has on_message_begin: ptr,
            on_url: Callable[[ptr, ptr[u8], u64], i32],
            on_status: ptr,
            on_method: ptr,
            on_version: ptr,
            on_header_field: Callable[[ptr, ptr[u8], u64], i32],
            on_header_value: Callable[[ptr, ptr[u8], u64], i32],
            on_chunk_extension_name: ptr,
            on_chunk_extension_value: ptr,
            on_headers_complete: ptr,
            on_body: Callable[[ptr, ptr[u8], u64], i32],
            on_message_complete: Callable[[ptr], i32],
            on_url_complete: ptr,
            on_status_complete: ptr,
            on_method_complete: ptr,
            on_version_complete: ptr,
            on_header_field_complete: ptr,
            on_header_value_complete: Callable[[ptr], i32],
            on_chunk_extension_name_complete: ptr,
            on_chunk_extension_value_complete: ptr,
            on_chunk_header: ptr,
            on_chunk_complete: ptr,
            on_reset: ptr;
    }  def llhttp_init(parser: ptr, kind: i32, settings: ptr) -> None;  def llhttp_execute(
        parser: ptr, data: ptr[u8], length: u64
    ) -> i32;  def llhttp_get_method(parser: ptr) -> u8;
}

obj:pub HttpHandler {
    def request(connection: Connection) {
        connection.respond(404, b"Not found");
    }

    def disconnected(connection: Connection) {
        _ = connection;
    }
}

glob _connections: dict[int, Connection] = {},
     _writes: dict[int, Write] = {},
     _settings: ptr[Settings] = ptr[Settings](),
     _handler: HttpHandler = HttpHandler();

obj Write {
    has stream: ptr,
        memory: ptr[u8];
}

obj:pub Connection {
    has stream: ptr,
        parser: ptr = ptr(),
        path: str = "",
        body: bytes = b"",
        method: int = 0,
        headers: dict[str, str] = {},
        field: str = "",
        value: str = "",
        received: int = 0,
        pending: int = 0,
        complete: bool = False,
        close_after_write: bool = False,
        streaming: bool = False,
        closed: bool = False;

    def initialize {
        self.parser = calloc(1, 96);
        llhttp_init(self.parser, 1, _settings);
        ptr[Parser](self.parser).view(1)[0].data = self.stream;
        _connections[int(self.stream)] = self;
    }

    def consume(data: ptr[u8], length: int) {
        if self.complete or self.close_after_write {
            return;
        }
        self.received += length;
        if self.received > 131072 {
            self.respond(413, b"Request too large.");
            return;
        }
        code = llhttp_execute(self.parser, data, u64(length));
        if code != 0 and code != 21 {
            self.respond(400, b"Invalid HTTP request.");
        }
    }

    def dispose {
        free(self.parser);
        self.parser = ptr();
        del _connections[int(self.stream)];
    }

    def send(data: bytes) {
        if self.closed {
            return;
        }
        memory = ptr[u8](calloc(u64(len(data) + 1), 1));
        for i in range(len(data)) {
            memory.view(len(data) + 1)[i] = u8(data[i]);
        }
        req = calloc(1, uv_req_size(3));
        _writes[int(req)] = Write(stream=self.stream, memory=memory);
        self.pending += 1;
        buffer = make_buffer(memory, len(data));
        code = uv_write(req, self.stream, &buffer, 1, written);
        if code < 0 {
            self.pending -= 1;
            del _writes[int(req)];
            free(req);
            free(memory);
            self.close();
        }
    }

    def respond(
        status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8"
    ) {
        headers = f"HTTP/1.1 {status} Response\r\nContent-Length: {len(
            body
        )}\r\nContent-Type: {content_type}\r\nConnection: close\r\n"
            + security_headers()
            + "\r\n";
        self.send(headers.encode("utf-8") + body);
        self.close_after_write = True;
        if self.pending == 0 {
            self.close();
        }
    }

    def start_stream {
        self.streaming = True;
        self.send(
            (
                "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n"
                + security_headers()
                + "\r\n"
            ).encode(
                "utf-8"
            )
        );
    }

    def chunk(text: str) {
        if self.closed {
            return;
        }
        body = text.encode("utf-8");
        # HTTP chunk sizes are hexadecimal; avoid runtime-dependent formatting.
        number = len(body);
        digits = "0123456789abcdef";
        size = "";
        while number > 0 {
            size = digits[number % 16] + size;
            number //= 16;
        }
        if size == "" {
            return;
        }
        self.send(size.encode("utf-8") + b"\r\n" + body + b"\r\n");
    }

    def finish_stream {
        if self.closed {
            return;
        }
        self.send(b"0\r\n\r\n");
        self.close_after_write = True;
        if self.pending == 0 {
            self.close();
        }
    }

    def close {
        if self.closed {
            return;
        }
        self.closed = True;
        _handler.disconnected(self);
        uv_read_stop(self.stream);
        if uv_is_closing(self.stream) == 0 {
            uv_close(self.stream, closed);
        }
    }
}

def security_headers -> str {
    return "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'\r\n";
}

def closed(handle: ptr) {
    connection = _connections[int(handle)];
    connection.dispose();
    free(handle);
}

def written(request: ptr, status: i32) {
    operation = _writes[int(request)];
    connection = _connections[int(operation.stream)];
    free(operation.memory);
    free(request);
    del _writes[int(request)];
    connection.pending -= 1;
    if status < 0 or (connection.close_after_write and connection.pending == 0) {
        connection.close();
    }
}

def bytes_at(data: ptr[u8], length: u64) -> bytes {
    values: list[int] = [];
    for i in range(int(length)) {
        values.append(int(data.view(int(length))[i]));
    }
    return bytes(values);
}

def parsed_connection(parser: ptr) -> Connection {
    return _connections[int(ptr[Parser](parser).view(1)[0].data)];
}

def url_part(parser: ptr, data: ptr[u8], length: u64) -> i32 {
    connection = parsed_connection(parser);
    connection.path += bytes_at(data, length).decode("utf-8", "replace");
    return 0;
}

def field_part(parser: ptr, data: ptr[u8], length: u64) -> i32 {
    connection = parsed_connection(parser);
    connection.field += bytes_at(data, length).decode("utf-8", "replace");
    return 0;
}

def value_part(parser: ptr, data: ptr[u8], length: u64) -> i32 {
    connection = parsed_connection(parser);
    connection.value += bytes_at(data, length).decode("utf-8", "replace");
    return 0;
}

def header_complete(parser: ptr) -> i32 {
    connection = parsed_connection(parser);
    name = connection.field.lower();
    if name in connection.headers {
        return 1;
    }
    connection.headers[name] = connection.value.strip();
    connection.field = "";
    connection.value = "";
    return 0;
}

def body_part(parser: ptr, data: ptr[u8], length: u64) -> i32 {
    parsed_connection(parser).body += bytes_at(data, length);
    return 0;
}

def message_complete(parser: ptr) -> i32 {
    connection = parsed_connection(parser);
    connection.complete = True;
    connection.method = int(llhttp_get_method(parser));
    try {
        _handler.request(connection);
    } except Exception {
        connection.respond(500, b"Request failed.");
    }
    return 21;
}

def allocate(_handle: ptr, _suggested: u64, buffer: &mut Buffer) {
    buffer.base = ptr[u8](calloc(65536, 1));
    buffer.length = 65536;
}

def read_client(stream: ptr, count: i64, buffer: &Buffer) {
    connection = _connections[int(stream)];
    try {
        if count < 0 {
            connection.close();
            return;
        }
        if count == 0 {
            return;
        }
        connection.consume(buffer.base, int(count));
    } finally {
        free(buffer.base);
    }
}

def accepted(listener: ptr, status: i32) {
    if status < 0 {
        return;
    }
    stream = new_handle(12);
    checked(uv_tcp_init(uv_default_loop(), stream), "Initialize client socket");
    if uv_accept(listener, stream) < 0 {
        close_handle(stream);
        return;
    }
    connection = Connection(stream=stream);
    connection.initialize();
    checked(uv_read_start(stream, allocate, read_client), "Read browser request");
}

obj:pub HttpServer {
    has handler: HttpHandler,
        listener: ptr = ptr(),
        port: int = 0;

    def prepare {
        _handler = self.handler;
        _settings = ptr[Settings](calloc(1, 184));
        settings = _settings.view(1);
        settings[0].on_url = url_part;
        settings[0].on_header_field = field_part;
        settings[0].on_header_value = value_part;
        settings[0].on_header_value_complete = header_complete;
        settings[0].on_body = body_part;
        settings[0].on_message_complete = message_complete;
    }

    def start {
        self.prepare();
        self.listener = new_handle(12);
        checked(
            uv_tcp_init(uv_default_loop(), self.listener), "Initialize loopback server"
        );
        address = ptr[u8](calloc(128, 1));
        try {
            checked(uv_ip4_addr("127.0.0.1", 0, address), "Resolve loopback address");
            checked(uv_tcp_bind(self.listener, address, 0), "Bind loopback server");
            checked(uv_listen(self.listener, 128, accepted), "Listen on loopback");
            length: i32 = 128;
            checked(
                uv_tcp_getsockname(self.listener, address, &mut length),
                "Read loopback port"
            );
            self.port = int(address.view(4)[2]) * 256 + int(address.view(4)[3]);
        } finally {
            free(address);
        }
    }

    def stop {
        close_handle(self.listener);
        streams: list[int] = [];
        for stream in _connections {
            streams.append(stream);
        }
        for stream in streams {
            _connections[stream].close();
        }
    }

    def release {
        if not _settings.is_null() {
            free(_settings);
            _settings = ptr[Settings]();
        }
    }
}
