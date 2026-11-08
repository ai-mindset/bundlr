"""Prepare checksum-guarded Jac 0.39.1 compatibility fixes."""
import hashlib;
import argparse;
import json;
import os;
import tempfile;
import jaclang;
import jaclang.cli.browser_engine as browser_engine;
import subprocess;
import time;
import from importlib.metadata { version }
import from pathlib { Path }
import from scripts.prepare_uv { host_target }

def:pub patch_windows_regex(package: Path, enabled: bool = True) {
    # Jac's regex cache spinlock calls POSIX sched_yield, which Windows UCRT
    # does not export. Use Kernel32 only in a compiler prepared for Windows;
    # restore the original sources before compiling any Unix target.
    patches = [
        (
            "re.jac",
            "8f7b6c484a07e07c52b5c425d63158682a842da22bbb1adde25a291469062e26",
            "import from c { def sched_yield -> i32;  }",
            "import from kernel32 { def SwitchToThread -> i32;  }"
        ),
        (
            "impl/re.impl.jac",
            "f8a84be23bc9386a38e36f4553ab0f1b837f43f06d4937f54c0480718d21af08",
            "        sched_yield();",
            "        SwitchToThread();"
        )
    ];
    updates: list[tuple[Path, bytes]] = [];
    for (name, checksum, before, after) in patches {
        path = package / "runtime/na_stdlib" / name;
        content = path.read_bytes();
        original = content.replace(after.encode(), before.encode());
        if hashlib.sha256(original).hexdigest() != checksum {
            raise RuntimeError(
                "Unexpected Jac regex runtime; refusing to patch " + str(path)
            );
        }
        patched = original.replace(before.encode(), after.encode())
            if enabled
            else original;
        if content != patched {
            updates.append((path, patched));
        }
    }
    # Validate all files before changing any; interrupted preparation is
    # safe to repeat and unknown compiler revisions fail without modification.
    for (path, content) in updates {
        with tempfile.TemporaryDirectory(
            prefix=".bundlr-jac-", dir=path.parent
        ) as temporary {
            staged = Path(temporary) / path.name;
            staged.write_bytes(content);
            staged.replace(path);
        }
    }
}

def:pub prepare_native_runtime(target: str) {
    package = Path(jaclang.__file__).resolve().parent;
    windows = target == "windows-x86_64";
    if not windows
        and not any(
            b"SwitchToThread" in (package / "runtime/na_stdlib" / name).read_bytes()
            for name in ["re.jac", "impl/re.impl.jac"]
        ) {
        return;
    }
    lock = json.loads(Path("build-lock.json").read_text());
    if lock["jacVersion"] != "0.39.1" or version("jaclang") != "0.39.1" {
        raise RuntimeError(
            "The Windows regex runtime patch requires pinned Jac 0.39.1."
        );
    }
    cache = os.environ.get("JAC_CACHE_HOME", "");
    if not cache or not package.is_relative_to(Path(cache).resolve()) {
        raise RuntimeError(
            "Set JAC_CACHE_HOME to an isolated build cache before compiling Windows."
        );
    }
    patch_windows_regex(package, windows);
    print("Prepared Jac 0.39.1 regex runtime for " + target + ".");
}

def:pub launch_browser(
    session: str = "default", viewport: str = "1280x720"
) -> dict[str, object] {
    # Jac 0.39.1's launch body, with stale readiness removed before spawning.
    # Keep the upstream session, viewport and timeout behavior unchanged.
    st = browser_engine.load_state(session);
    if st and browser_engine._pid_alive(st["pid"]) {
        try {
            browser_engine._http_json(st["port"], "/json/version");
            return st;
        } except OSError {}
    }
    cache = browser_engine.get_cache_dir();
    cache.mkdir(parents=True, exist_ok=True);
    profile = cache / f"profile-{session}";
    chrome = browser_engine._find_chrome();
    port_file = profile / "DevToolsActivePort";
    port_file.unlink(missing_ok=True);
    proc = subprocess.Popen(
        browser_engine._chrome_args(chrome, profile, viewport),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    );
    port: int | None = None;
    for _ in range(100) {
        if port_file.exists() {
            port = int(port_file.read_text().splitlines()[0]);
            break;
        }
        time.sleep(0.1);
    }
    if port is None {
        proc.kill();
        raise RuntimeError("Chrome failed to start (no DevToolsActivePort)");
    }
    (vw, vh) = browser_engine._parse_viewport(viewport);
    browser_engine._calibrate_viewport(port, vw, vh);
    st = {"session": session, "pid": proc.pid, "port": port};
    browser_engine._state_path(session).write_text(json.dumps(st));
    return st;
}

def:pub prepare_browser_runtime {
    package = Path(jaclang.__file__).resolve().parent;
    lock = json.loads(Path("build-lock.json").read_text());
    if lock["jacVersion"] != "0.39.1" or version("jaclang") != "0.39.1" {
        raise RuntimeError("The browser startup fix requires pinned Jac 0.39.1.");
    }
    # Released Jac uses sealed bytecode, so replace only this process's function.
    # Installed sources, sealed artifacts, and integrity checks stay intact.
    content = (package / "cli/impl/browser_engine.impl.jac").read_bytes();
    if hashlib.sha256(content).hexdigest()
        != "2d3846b51052a6bc910e410eae27f794ab592dfa82fc706a2ba2ac5d55c1b1a7" {
        raise RuntimeError("Unexpected Jac browser runtime; refusing to patch it.");
    }
    setattr(browser_engine, "launch", launch_browser);
}

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("--target", `default=host_target());
    prepare_native_runtime(parser.parse_args().target);
}
