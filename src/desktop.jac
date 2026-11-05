"""Native loopback browser interface over the shared packaging engine."""
import time;
import os;
import json;
import sys;
import from src.domain.request { decode_request, current_target, BUNDLR_VERSION }
import from src.core.build_job { BuildJob, BuildEvents }
import from src.platform.http { HttpServer, HttpHandler, Connection }
import from src.platform.files {
    native_path,
    parent_path,
    join_path,
    read_text,
    read_bytes,
    random_token
}
import from src.platform.processes { ProcessEvents, start_child }
import from src.platform.ffi_uv { uv_run, uv_default_loop, uv_loop_alive }
import from src.platform.cancellation { cancellation_requested }

obj QuietEvents(ProcessEvents) {
    override def stdout(text: str) {
        _ = text;
    }

    override def stderr(text: str) {
        _ = text;
    }
}

obj BrowserEvents(BuildEvents) {
    has connection: Connection;

    def send(value: dict[str, str | list[dict[str, str]]]) {
        self.connection.chunk(json.dumps(value) + "\n");
    }

    override def stdout(text: str) {
        self.send({"type": "output", "stream": "stdout", "text": text});
    }

    override def stderr(text: str) {
        self.send({"type": "output", "stream": "stderr", "text": text});
    }

    override def finished(results: list[dict[str, str]]) {
        self.send({"type": "done", "results": results});
        self.connection.finish_stream();
    }

    override def failed(message: str) {
        self.send({"type": "error", "message": message});
        self.connection.finish_stream();
    }
}

obj:pub DesktopHandler(HttpHandler) {
    has origin: str = "",
        token: str = "",
        assets: str = "",
        sessions: dict[str, float] = {},
        job: BuildJob | None = None,
        job_connection: Connection | None = None,
        stopping: bool = False,
        opened_at: float = 0.0,
        closed_at: float = -1.0;

    override def request(connection: Connection) {
        if connection.headers.get("host", "") != self.origin[7:] {
            connection.respond(403, b"Forbidden");
            return;
        }
        if connection.method == 1 {
            if connection.path == "/" {
                page_id = random_token();
                self.sessions[page_id] = time.monotonic();
                self.closed_at = -1.0;
                config: dict[str, str] = {
                    "token": self.token,
                    "pageId": page_id,
                    "target": current_target(),
                    "version": BUNDLR_VERSION
                };
                html = read_text(join_path(self.assets, "index.html")).replace(
                    "{{CONFIG}}", json.dumps(config)
                );
                connection.respond(
                    200, html.encode("utf-8"), "text/html; charset=utf-8"
                );
                return;
            }
            if connection.path == "/ui.js" {
                connection.respond(
                    200,
                    read_bytes(join_path(self.assets, "ui.js")),
                    "text/javascript; charset=utf-8"
                );
                return;
            }
            if connection.path == "/jac_prelude.js" {
                connection.respond(
                    200,
                    read_bytes(join_path(self.assets, "jac_prelude.js")),
                    "text/javascript; charset=utf-8"
                );
                return;
            }
            if connection.path == "/style.css" {
                connection.respond(
                    200,
                    read_bytes(join_path(self.assets, "style.css")),
                    "text/css; charset=utf-8"
                );
                return;
            }
            connection.respond(404, b"Not found");
            return;
        }
        if connection.method != 3
            or connection.headers.get("x-bundlr-token", "") != self.token {
            connection.respond(403, b"Forbidden");
            return;
        }
        if "origin" in connection.headers
            and connection.headers["origin"] != self.origin {
            connection.respond(403, b"Forbidden");
            return;
        }
        if connection.path == "/cancel" {
            job = self.job;
            if job is not None {
                job.cancel();
            }
            connection.respond(204);
            return;
        }
        if connection.path == "/quit" {
            self.stopping = True;
            connection.respond(204);
            return;
        }
        page_id = connection.headers.get("x-bundlr-page", "");
        if connection.path == "/heartbeat" {
            if page_id in self.sessions {
                self.sessions[page_id] = time.monotonic();
            }
            connection.respond(204);
            return;
        }
        if connection.path == "/close" {
            if page_id in self.sessions {
                del self.sessions[page_id];
            }
            if len(self.sessions) == 0 {
                self.closed_at = time.monotonic();
            }
            connection.respond(204);
            return;
        }
        if connection.path != "/package" {
            connection.respond(404, b"Not found");
            return;
        }
        active = self.job;
        if active is not None and not active.done {
            connection.respond(409, b"A package build is already running.");
            return;
        }
        try {
            request = decode_request(connection.body.decode("utf-8"));
            job = BuildJob(
                request=request, events=BrowserEvents(connection=connection)
            );
            job.start();
            self.job = job;
            self.job_connection = connection;
            connection.start_stream();
        } except Exception as error {
            connection.respond(400, str(error).encode("utf-8"));
        }
    }

    override def disconnected(connection: Connection) {
        active_connection = self.job_connection;
        active = self.job;
        if active_connection is not None
            and active_connection.stream == connection.stream
            and active is not None
            and not active.done {
            active.cancel();
        }
    }

    def tick {
        now = time.monotonic();
        expired: list[str] = [];
        for page_id in self.sessions {
            if now - self.sessions[page_id] > 600.0 {
                expired.append(page_id);
            }
        }
        for page_id in expired {
            del self.sessions[page_id];
        }
        if len(self.sessions) == 0 and now - self.opened_at > 600.0 {
            self.stopping = True;
        }
        if self.closed_at >= 0.0 and now - self.closed_at >= 2.0 {
            self.stopping = True;
        }
        if cancellation_requested() {
            self.stopping = True;
        }
        active = self.job;
        if active is not None and not active.done {
            if self.stopping {
                active.cancel();
            }
            active.advance();
        }
    }
}

def:pub start_desktop -> int {
    handler = DesktopHandler(
        token=random_token(),
        assets=join_path(parent_path(native_path(True)), "data"),
        opened_at=time.monotonic()
    );
    server = HttpServer(handler=handler);
    server.start();
    handler.origin = f"http://127.0.0.1:{server.port}";
    print("Bundlr browser interface: " + handler.origin + "/");
    sys.stdout.flush();
    if os.getenv("BUNDLR_NO_BROWSER") != "1" {
        opener = "xdg-open";
        if sys.platform == "darwin" {
            opener = "open";
        } elif sys.platform == "win32" {
            opener = "explorer.exe";
        }
        try {
            start_child(
                opener, [handler.origin + "/"], QuietEvents(), contain_tree=False
            );
        } except Exception {}
    }
    try {
        while True {
            uv_run(uv_default_loop(), 2);
            handler.tick();
            active = handler.job;
            if handler.stopping and (active is None or active.done) {
                break;
            }
            time.sleep(0.001);
        }
    } finally {
        server.stop();
        for i in range(10) {
            uv_run(uv_default_loop(), 2);
            time.sleep(0.001);
        }
        server.release();
    }
    return 0;
}
