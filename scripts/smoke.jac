"""Offline uv integrity, live loopback controls and optional real browser acceptance."""
import argparse;
import gzip;
import json;
import os;
import re;
import shutil;
import subprocess;
import sys;
import tempfile;
import time;
import from pathlib { Path }
import from urllib.request { Request, urlopen }
import from urllib.error { HTTPError }

def diagnose(binary: Path, environment: dict[str, str], success: bool = True) {
    result = subprocess.run(
        [str(binary), "--diagnose"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=60
    );
    assert (result.returncode == 0) == success , result.stdout + result.stderr;
}

def request(
    url: str, headers: dict[str, str], body: bytes | None = None, status: int = 200
) -> bytes {
    try {
        with urlopen(
            Request(url, data=body, headers=headers), timeout=30
        ) as response {
            assert response.status == status;
            return response.read();
        }
    } except HTTPError as error {
        assert error.code == status , str(error);
        return error.read();
    }
}

def browse(args: list[str]) -> str {
    result = subprocess.run(
        ["jac", "run", "scripts/browser.jac", "--"] + args,
        env=dict(os.environ, JACBROWSER_SESSION="bundlr-smoke"),
        capture_output=True,
        text=True,
        timeout=30
    );
    if result.returncode != 0 {
        raise RuntimeError(
            "jac browse "
                + " ".join(args)
                + " failed:\n"
                + result.stdout
                + result.stderr
        );
    }
    return result.stdout.strip();
}

def wait_status(prefix: str, timeout: float = 180.0) -> str {
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        status = browse(["get", "text", "#status"]);
        if status.startswith(prefix) {
            return status;
        }
        if status.startswith("Error:") and prefix != "Error:" {
            raise RuntimeError(status);
        }
        time.sleep(0.1);
    }
    raise RuntimeError(
        "Browser did not reach status: " + prefix + "\n" + browse(["console"])
    );
}

def browser_acceptance(origin: str, directory: Path, process: subprocess.Popen[bytes]) {
    try {
        browse(["open", origin]);
        assert browse(["get", "title"]) == "Bundlr";
        browse(["wait", "#source"]);
        browse(["fill", "#source", "unpinned"]);
        browse(["click", "#package"]);
        assert "pinned" in wait_status("Error:");
        browse(["fill", "#source", "black==26.5.1"]);
        browse(["fill", "#outputDirectory", str(directory)]);
        browse(["click", "#package"]);
        browse(["click", "#cancel"]);
        assert "cancelled" in wait_status("Error:").lower();
        browse(["click", "#package"]);
        wait_status("Created ");
        assert len(list(directory.glob("*.sha256"))) == 1;
        assert "Packaging" in browse(["get", "text", "#output"]);
        browse(["fill", "#outputDirectory", str(directory / "shutdown")]);
        browse(["click", "#package"]);
        browse(["click", "#quit"]);
        assert "Bundlr has stopped" in wait_status("Bundlr has stopped");
        assert process.wait(timeout=20) == 0;
        assert "Bundlr has stopped" in browse(["get", "text", "#status"]);
    } finally {
        failed = sys.exc_info()[0] is not None;
        try {
            browse(["close"]);
        } except Exception as error {
            if not failed {
                raise;
            }
            print("Browser cleanup failed: " + str(error), file=sys.stderr);
        }
    }
}

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("--runtime", required=True);
    parser.add_argument("--browser", action="store_true");
    parser.add_argument("--log-directory");
    args = parser.parse_args();
    runtime = Path(args.runtime).resolve();
    binary = runtime / ("bundlr.exe" if os.name == "nt" else "bundlr");
    with tempfile.TemporaryDirectory(prefix="bundlr-smoke-") as temporary {
        base = Path(temporary);
        environment = dict(os.environ);
        environment["BUNDLR_CACHE_DIRECTORY"] = str(base / "cache");
        environment["BUNDLR_NO_BROWSER"] = "1";
        diagnose(binary, environment);
        cached = list((base / "cache").rglob("uv.exe" if os.name == "nt" else "uv"));
        assert len(cached) == 1;
        cached[0].write_bytes(b"corrupted cached tool");
        diagnose(binary, environment);
        invalid = base / "invalid-uv";
        invalid.write_bytes(b"unverified override");
        overridden = dict(environment);
        overridden["BUNDLR_UV_EXECUTABLE"] = str(invalid);
        diagnose(binary, overridden, False);
        damaged = base / "damaged-runtime";
        shutil.copytree(runtime, damaged, symlinks=True);
        (damaged / "data/uv.gz").write_bytes(gzip.compress(b"unverified payload"));
        environment["BUNDLR_CACHE_DIRECTORY"] = str(base / "fresh-cache");
        diagnose(damaged / binary.name, environment, False);
        print("Offline tool integrity and cache repair passed.");
        logs = Path(args.log_directory).resolve() if args.log_directory else base;
        logs.mkdir(parents=True, exist_ok=True);
        log = logs / "desktop.log";
        with log.open("w") as output {
            server = subprocess.Popen(
                [str(binary)], env=environment, stdout=output, stderr=subprocess.STDOUT
            );
            try {
                origin = "";
                deadline = time.monotonic() + 20.0;
                while time.monotonic() < deadline {
                    matched = re.search(r"http://127\.0\.0\.1:[0-9]+", log.read_text());
                    if matched is not None {
                        origin = matched.group(0);
                        break;
                    }
                    if server.poll() is not None {
                        raise RuntimeError(log.read_text());
                    }
                    time.sleep(0.05);
                }
                assert origin != "" , log.read_text();
                html = request(origin + "/", {}).decode();
                matched = re.search(
                    r'<script id="config" type="application/json">([^<]+)</script>',
                    html
                );
                assert matched is not None;
                config = json.loads(matched.group(1));
                token = {"x-bundlr-token": config["token"], "origin": origin};
                request(origin + "/quit", {}, b"", 403);
                request(origin + "/quit", {"host": "attacker.example"}, b"", 403);
                request(
                    origin + "/quit",
                    {
                        "x-bundlr-token": config["token"],
                        "origin": "https://attacker.example"
                    },
                    b"",
                    403
                );
                request(
                    origin + "/package",
                    token,
                    b'{"source":"unpinned","targets":["linux-x86_64"]}',
                    400
                );
                assert server.poll() is None;
                if args.browser {
                    browser_acceptance(origin, base / "applications", server);
                } else {
                    request(origin + "/quit", token, b"", 204);
                }
                assert server.wait(timeout=20) == 0 , log.read_text();
                print(
                    "Live loopback controls"
                        + (" and browser packaging" if args.browser else "")
                        + " passed."
                );
            } finally {
                if server.poll() is None {
                    server.terminate();
                    server.wait(timeout=10);
                }
            }
        }
    }
}
