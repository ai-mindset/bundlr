import sys;
import time;
import from src.domain.request { parse_cli, BUNDLR_VERSION }
import from src.core.build_job { BuildJob, BuildEvents }
import from src.desktop { start_desktop }
import from src.platform.uv_runtime { resolve_uv, UV_VERSION }
import from src.platform.processes { start_child, ProcessEvents }
import from src.platform.ffi_uv { uv_default_loop, uv_run, uv_version_string }
import from src.platform.cancellation {
    install_signals,
    remove_signals,
    cancellation_requested
}

glob HELP: str = """Package a Python application as a self-contained application.

Usage:
  bundlr                         Open the browser interface
  bundlr [OPTIONS] <PACKAGE>
  bundlr package [OPTIONS] <PACKAGE>

Options:
  -n, --name <NAME>       Application name (default: inferred from source)
  -c, --command <NAME>    Python application entry point (default: auto-detect)
  -k, --kind <KIND>       auto, windowed, or console (default: auto)
  -p, --python <VERSION>  Python version (default: 3.12)
  -t, --target <TARGET>   Repeatable target or all (default: current platform)
  -o, --output <PATH>     Output directory (default: dist)
  -h, --help             Show this help
  -V, --version          Show the Bundlr version
      --diagnose         Verify the bundled runtime tools without network access

Targets: linux-x86_64, windows-x86_64, macos-arm64, macos-x86_64
Sources: name[extras]==version or HTTPS Git URL, optionally with @revision
""";

obj DiagnosticEvents(ProcessEvents) {
    has errors: str = "";

    override def stdout(text: str) {
        _ = text;
    }

    override def stderr(text: str) {
        self.errors += text;
    }
}

def diagnose -> int {
    events = DiagnosticEvents();
    child = start_child(resolve_uv(), ["--version"], events, capture=True);
    while not child.done() {
        uv_run(uv_default_loop(), 2);
        if cancellation_requested() {
            child.cancel();
        }
        time.sleep(0.001);
    }
    if child.code != 0 {
        raise RuntimeError("uv diagnostic failed: " + events.errors);
    }
    version = child.output.strip();
    if not version.startswith("uv " + UV_VERSION + " ") {
        raise RuntimeError("Unexpected bundled uv version: " + version);
    }
    print(
        f"Bundlr {BUNDLR_VERSION}\n{version}\nlibuv {uv_version_string()}\nRuntime diagnostic passed."
    );
    return 0;
}

def:pub main(args: list[str]) -> int {
    if len(args) > 1 and args[0] == "package" {
        args = args[1:];
    }
    handles = install_signals();
    try {
        if len(args) == 0 {
            return start_desktop();
        }
        command = args[0];
        if command == "--help" or command == "-h" {
            print(f"Bundlr {BUNDLR_VERSION}\n\n{HELP}");
            return 0;
        }
        if command == "--version" or command == "-V" {
            print(BUNDLR_VERSION);
            return 0;
        }
        if command == "--diagnose" {
            return diagnose();
        }
        request = parse_cli(args);
        job = BuildJob(request=request, events=BuildEvents());
        job.start();
        while not job.done {
            uv_run(uv_default_loop(), 2);
            if cancellation_requested() {
                job.cancel();
            }
            job.advance();
            time.sleep(0.001);
        }
        if job.error != "" {
            return 1;
        }
        return 0;
    } except ValueError as error {
        sys.stderr.write("Error: " + str(error) + "\n\nRun bundlr --help for usage.\n");
        return 2;
    } except Exception as error {
        sys.stderr.write("Error: " + str(error) + "\n");
        return 1;
    } finally {
        remove_signals(handles);
        uv_run(uv_default_loop(), 2);
    }
}

with entry {
    sys.`exit(main(sys.argv[1:]));
}
