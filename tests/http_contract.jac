import from src.platform.http { Connection, HttpServer, HttpHandler }
import from src.platform.ffi_uv { calloc, free }
import from src.desktop { DesktopHandler, BrowserEvents }
import json;

obj RecordingStream(Connection) {
    has chunks: list[str] = [],
        endings: int = 0;

    override def chunk(text: str) {
        self.chunks.append(text);
    }

    override def finish_stream {
        self.endings += 1;
    }
}

obj MemoryConnection(Connection) {
    has status: int = 0,
        response: bytes = b"";

    override def respond(
        status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8"
    ) {
        _ = content_type;
        self.status = status;
        self.response = body;
        self.close_after_write = True;
    }
}

obj RecordingHandler(HttpHandler) {
    has requests: int = 0;

    override def request(connection: Connection) {
        assert connection.path == "/test";
        assert connection.method == 3;
        assert connection.headers["host"] == "127.0.0.1:1234";
        assert connection.body == b"hello";
        self.requests += 1;
        connection.respond(204);
    }
}

def feed(connection: Connection, body: bytes) {
    memory = ptr[u8](calloc(u64(len(body)), 1));
    try {
        for i in range(len(body)) {
            memory.view(len(body))[i] = u8(body[i]);
        }
        connection.consume(memory, len(body));
    } finally {
        free(memory);
    }
}

def:pub check_http {
    recording = RecordingStream(stream=ptr());
    events = BrowserEvents(connection=recording);
    events.stdout("stdout\n");
    events.stderr("stderr\n");
    events.failed("failure");
    events.finished([{"archivePath": "application.zip", "target": "windows-x86_64"}]);
    assert len(recording.chunks) == 4;
    for (index, name) in [(0, "stdout"), (1, "stderr")] {
        output = json.loads(recording.chunks[index]);
        assert len(output) == 3;
        assert output["type"] == "output";
        assert output["stream"] == name;
        assert output["text"] == name + "\n";
    }
    failure = json.loads(recording.chunks[2]);
    assert len(failure) == 2;
    assert failure["type"] == "error";
    assert failure["message"] == "failure";
    result = json.loads(recording.chunks[3]);
    assert len(result) == 2;
    assert result["type"] == "done";
    assert len(result["results"]) == 1;
    assert len(result["results"][0]) == 2;
    assert result["results"][0]["archivePath"] == "application.zip";
    assert result["results"][0]["target"] == "windows-x86_64";
    assert recording.endings == 2;
    handler = RecordingHandler();
    server = HttpServer(handler=handler);
    server.prepare();
    for request in [
        b"POST /test HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 5\r\n\r\nhello",
        b"POST /test HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    ] {
        stream = calloc(1, 8);
        connection = MemoryConnection(stream=stream);
        connection.initialize();
        try {
            for i in range(0, len(request), 3) {
                feed(connection, request[i:i + 3]);
            }
            assert connection.status == 204;
        } finally {
            connection.dispose();
            free(stream);
        }
    }
    assert handler.requests == 2;
    for request in [
        b"GET /test HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        b"POST /test HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        b"INVALID HTTP\r\n\r\n"
    ] {
        stream = calloc(1, 8);
        connection = MemoryConnection(stream=stream);
        connection.initialize();
        try {
            feed(connection, request);
            assert connection.status == 400;
        } finally {
            connection.dispose();
            free(stream);
        }
    }
    stream = calloc(1, 8);
    connection = MemoryConnection(stream=stream);
    connection.initialize();
    try {
        feed(connection, b"x" * 131073);
        assert connection.status == 413;
    } finally {
        connection.dispose();
        free(stream);
    }
    server.release();
    desktop = DesktopHandler(origin="http://127.0.0.1:1234", token="secret");
    for headers in [
        {"host": "attacker.example", "x-bundlr-token": "secret"},
        {"host": "127.0.0.1:1234"},
        {
            "host": "127.0.0.1:1234",
            "x-bundlr-token": "secret",
            "origin": "https://attacker.example"
        }
    ] {
        connection = MemoryConnection(
            stream=ptr(), method=3, path="/quit", headers=headers
        );
        desktop.request(connection);
        assert connection.status == 403;
        assert not desktop.stopping;
    }
    connection = MemoryConnection(
        stream=ptr(),
        method=3,
        path="/quit",
        headers={
            "host": "127.0.0.1:1234",
            "x-bundlr-token": "secret",
            "origin": desktop.origin
        }
    );
    desktop.request(connection);
    assert connection.status == 204;
    assert desktop.stopping;
}
