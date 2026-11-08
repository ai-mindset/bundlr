"""Developer-tool regressions; application behavior is exercised by native_test.jac."""
import hashlib;
import json;
import os;
import jaclang;
import jaclang.cli.browser_engine as browser_engine;
import jaclang.dist.seal as seal;
import subprocess;
import tempfile;
import from pathlib { Path }
import from unittest.mock { MagicMock, patch }
import from jaclang.project.config { get_config }
import from jaclang.project.kinds { plan_app_run }
import from scripts.build { audit_runtime, copy_libraries }
import from scripts.prepare_jac {
    patch_windows_regex,
    prepare_native_runtime,
    launch_browser,
    prepare_browser_runtime
}
import from scripts.smoke { browse, browser_acceptance }

def:pub check_tooling {
    lock = json.loads(Path("build-lock.json").read_text()) as dict[str, object];
    with tempfile.TemporaryDirectory(prefix="bundlr-tooling-") as temporary {
        base = Path(temporary);
        source = base / "source";
        output = base / "output";
        source.mkdir();
        output.mkdir();
        (source / "licenses").mkdir();
        (source / "licenses/test.txt").write_text("Synthetic licence");
        library = b"synthetic library";
        (source / "libtest.so.1").write_bytes(library);
        names = ["libtest.so.1"];
        if os.name != "nt" {
            (source / "libtest.so").symlink_to("libtest.so.1");
            names.append("libtest.so");
        }
        libraries = [
            {"name": name, "sha256": hashlib.sha256(library).hexdigest()}
            for name in names
        ];
        (source / "native-dependencies.json").write_text(
            json.dumps(
                {
                    "vcpkgBaseline": lock["vcpkgBaseline"],
                    "target": "linux-x86_64",
                    "libraries": libraries
                }
            )
        );
        # Regression: gstack review, 2026-11-04. Both licence directories and
        # SONAME links used to collide on the documented test command's second run.
        copy_libraries(source, output, lock, False, "linux-x86_64");
        copy_libraries(source, output, lock, False, "linux-x86_64");
        assert (output / "licenses/native/test.txt").read_text() == "Synthetic licence";
        if os.name != "nt" {
            assert (output / "libtest.so").is_symlink();
        }
        assert (output / "libtest.so.1").read_bytes() == library;
    }
    help = subprocess.check_output(
        ["jac", "run", "scripts/prepare_uv.jac", "--", "--help"], text=True
    );
    assert "--target TARGET" in help;
    check_native_build_plan();
    check_seal_exclusions();
    check_macos_audit();
    check_linux_audit();
    check_browser_errors();
    check_browser_startup();
    check_windows_regex_patch();
    print(
        "Developer helpers, platform audits, browser diagnostics and compiler patch contracts passed."
    );
}

def check_native_build_plan {
    config = get_config(start_path=Path.cwd(), force_discover=True);
    assert config is not None;
    plan = plan_app_run(config, str(config.project_root), config.resolve_app(""));
    assert plan.verb == "native" , "jac build must compile the native entry, not seal it.";
    assert Path(plan.entry_path).resolve() == Path("src/main.jac").resolve();
}

def check_seal_exclusions {
    ignore = Path(".jacignore");
    with tempfile.TemporaryDirectory(prefix="bundlr-seal-test-") as temporary {
        base = Path(temporary);
        source = base / "project";
        source.mkdir();
        (source / ".jacignore").write_text(
            ignore.read_text() if ignore.is_file() else ""
        );
        local_files = [
            "bundlr",
            ".build/generated.jac",
            ".agents/local.jac",
            ".aws/credentials",
            ".codex/config.toml",
            ".gstack/state.json"
        ];
        for name in ["src/main.jac", "ui/main.jac"] + local_files {
            path = source / name;
            path.parent.mkdir(parents=True, exist_ok=True);
            path.write_text("fixture");
        }
        # Exercise Jac's real staging filter and copy; skip compilation only.
        with patch.object(seal, "sealed_image_key", return_value=""), patch.object(
            seal, "vendor_packages"
        ), patch.object(seal, "bake_serve_payloads", return_value=True), patch.object(
            seal, "bake_native_payloads", return_value=True
        ), patch.object(seal, "run_precompiler", return_value=0) {
            image = seal.make_sealed_image(
                MagicMock(project_root=source), base / "output", "bundlr"
            );
        }
        assert image is not None;
        for name in local_files {
            assert not (image / name).exists() , "Local file entered seal: " + name;
        }
        for name in ["src/main.jac", "ui/main.jac"] {
            assert (image / name).read_text() == "fixture";
        }
    }
}

def check_windows_regex_patch {
    package = Path(jaclang.__file__).resolve().parent;
    names = ["re.jac", "impl/re.impl.jac"];
    originals: dict[str, bytes] = {};
    for name in names {
        content = (package / "runtime/na_stdlib" / name).read_bytes();
        # Tests accept both the pristine compiler and a prepared build cache.
        originals[name] = content.replace(
            b"import from kernel32 { def SwitchToThread -> i32;  }",
            b"import from c { def sched_yield -> i32;  }"
        ).replace(
            b"        SwitchToThread();", b"        sched_yield();"
        );
    }
    with tempfile.TemporaryDirectory(prefix="bundlr-compiler-patch-") as temporary {
        base = Path(temporary);
        for name in names {
            path = base / "runtime/na_stdlib" / name;
            path.parent.mkdir(parents=True, exist_ok=True);
            path.write_bytes(originals[name]);
        }
        patch_windows_regex(base);
        patched = [(base / "runtime/na_stdlib" / name).read_bytes() for name in names];
        assert b"SwitchToThread();" in patched[1];
        assert b"sched_yield" not in b"".join(patched);
        # Switching back to Unix restores the exact upstream bytes.
        patch_windows_regex(base, False);
        assert [(base / "runtime/na_stdlib" / name).read_bytes() for name in names]
            == [originals[name] for name in names];
        patch_windows_regex(base);
        # Repeated preparation and recovery from a partially applied patch.
        patch_windows_regex(base);
        (base / "runtime/na_stdlib/re.jac").write_bytes(originals["re.jac"]);
        patch_windows_regex(base);
        assert [(base / "runtime/na_stdlib" / name).read_bytes() for name in names]
            == patched;
        # Recover an interrupted restoration, where only the declaration was
        # restored, through the same entry point used by every native build.
        (base / "runtime/na_stdlib/re.jac").write_bytes(originals["re.jac"]);
        with patch.object(jaclang, "__file__", str(base / "__init__.py")), patch.dict(
            os.environ, {"JAC_CACHE_HOME": str(base)}
        ) {
            prepare_native_runtime("linux-x86_64");
        }
        assert [(base / "runtime/na_stdlib" / name).read_bytes() for name in names]
            == [originals[name] for name in names];
        # An unknown second file must fail before the first file is patched.
        declaration = base / "runtime/na_stdlib/re.jac";
        declaration.write_bytes(originals["re.jac"]);
        (base / "runtime/na_stdlib/impl/re.impl.jac").write_bytes(b"unknown runtime");
        rejected = False;
        try {
            patch_windows_regex(base);
        } except RuntimeError {
            rejected = True;
        }
        assert rejected;
        assert declaration.read_bytes() == originals["re.jac"];
    }
}

def check_macos_audit {
    with tempfile.TemporaryDirectory(prefix="bundlr-macos-audit-") as temporary {
        directory = Path(temporary);
        (directory / "bundlr").write_bytes(b"synthetic Mach-O fixture");
        (directory / "libtest.dylib").write_bytes(b"synthetic dylib fixture");
        for (dependency, valid) in [
            ("/usr/lib/libSystem.B.dylib", True),
            ("@loader_path/libtest.dylib", True),
            ("/opt/homebrew/lib/libbuilder.dylib", False),
            ("@loader_path/missing.dylib", False)
        ] {
            linked = "fixture:\n\t" + dependency + " (compatibility version 1.0.0)\n";
            rejected = False;
            with patch("platform.system", return_value="Darwin"), patch(
                "platform.machine", return_value="arm64"
            ), patch("subprocess.check_output", return_value=linked) {
                try {
                    audit_runtime(directory, "macos-x86_64");
                } except RuntimeError {
                    rejected = True;
                }
            }
            assert rejected != valid;
        }
    }
}

def check_linux_audit {
    with tempfile.TemporaryDirectory(prefix="bundlr-linux-audit-") as temporary {
        directory = Path(temporary);
        (directory / "bundlr").write_bytes(b"synthetic ELF fixture");
        (directory / "libtest.so").write_bytes(b"synthetic ELF library");
        for name in ["bundlr", "libtest.so"] {
            for (version, valid) in [
                ("2.2.5", True),
                ("2.9", True),
                ("2.35", True),
                ("2.36", False),
                ("2.100", False),
                ("PRIVATE", False),
                ("ABI_DT_RELR", False)
            ] {
                def output(args: list[str], text: bool = True) -> str {
                    assert text;
                    if args[0] == "readelf" {
                        return "Name: GLIBC_"
                            + (version if Path(args[2]).name == name else "2.34");
                    }
                    assert args[0] == "ldd";
                    return "libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x0)\n";
                }
                rejected = False;
                with patch("platform.system", return_value="Linux"), patch(
                    "platform.machine", return_value="x86_64"
                ), patch("subprocess.check_output", side_effect=output) {
                    try {
                        audit_runtime(directory, "linux-x86_64");
                    } except RuntimeError {
                        rejected = True;
                    }
                }
                assert rejected != valid , name + ": GLIBC_" + version;
            }
        }
    }
}

def check_browser_errors {
    result = subprocess.CompletedProcess(
        args=["jac", "browse"],
        returncode=1,
        stdout="browser stdout",
        stderr="Chrome startup failed"
    );
    with patch("subprocess.run", return_value=result) {
        rejected = False;
        try {
            browse(["open", "http://127.0.0.1:1234"]);
        } except RuntimeError as error {
            rejected = True;
            assert "browser stdout" in str(error);
            assert "Chrome startup failed" in str(error);
        }
        assert rejected;
    }
    # A second failure during cleanup must preserve the original startup error.
    with patch(
        "subprocess.run",
        side_effect=[
            subprocess.CompletedProcess(
                args=[], returncode=1, stdout="original browser failure", stderr=""
            ),
            subprocess.CompletedProcess(
                args=[], returncode=1, stdout="cleanup failure", stderr=""
            )
        ]
    ) {
        rejected = False;
        try {
            browser_acceptance(
                "http://127.0.0.1:1234",
                Path("unused"),
                MagicMock(spec=subprocess.Popen) as subprocess.Popen[bytes]
            );
        } except RuntimeError as error {
            rejected = True;
            assert "original browser failure" in str(error) , str(error);
            assert "cleanup failure" not in str(error);
        }
        assert rejected;
    }
}

def check_browser_startup {
    source = (
        Path(jaclang.__file__).resolve().parent / "cli/impl/browser_engine.impl.jac"
    ).read_bytes();
    original = browser_engine.launch;
    with patch.object(browser_engine, "launch", original), patch(
        "pathlib.Path.read_bytes", return_value=source + b"\n# unknown revision\n"
    ) {
        rejected = False;
        try {
            prepare_browser_runtime();
        } except RuntimeError {
            rejected = True;
        }
        assert rejected;
        assert browser_engine.launch is original;
    }
    # Every filesystem/process operation below is mocked. Chrome publishes
    # readiness inside Popen, forcing the scheduling order that exposed the race.
    for (enabled, publishes) in [(False, True), (True, True), (True, False)] {
        candidate = launch_browser if enabled else original;
        ready = {"exists": False};
        cache = MagicMock();
        port_file = cache.__truediv__.return_value.__truediv__.return_value;
        def ready_exists -> bool {
            return ready["exists"];
        }
        port_file.exists.side_effect = ready_exists;
        port_file.read_text.return_value = "9222\n/devtools/browser/fixture\n";
        def unlink(missing_ok: bool = False) {
            assert missing_ok;
            ready["exists"] = False;
        }
        port_file.unlink.side_effect = unlink;
        process = MagicMock(pid=123);
        def create_chrome(command: list[str], stdout: int, stderr: int) -> MagicMock {
            assert "--remote-debugging-port=0" in command;
            assert stdout == -3 and stderr == -3;
            ready["exists"] = publishes;
            return process;
        }
        with patch.multiple(
            browser_engine,
            load_state=MagicMock(return_value=None),
            get_cache_dir=MagicMock(return_value=cache),
            _find_chrome=MagicMock(return_value="/memory/chrome"),
            _calibrate_viewport=MagicMock(),
            _state_path=MagicMock()
        ), patch("subprocess.Popen", side_effect=create_chrome), patch("time.sleep") {
            rejected = False;
            try {
                result = candidate("fixture");
                assert result["port"] == 9222;
            } except RuntimeError as error {
                rejected = True;
                assert str(error) == "Chrome failed to start (no DevToolsActivePort)";
            }
            assert rejected == (not enabled or not publishes);
            assert process.kill.called == rejected;
            if enabled and publishes {
                # Exercise the actual CLI command's global launch lookup, too.
                with patch.object(browser_engine, "launch", original) {
                    prepare_browser_runtime();
                    assert browser_engine.launch is launch_browser;
                    prepare_browser_runtime();
                    assert browser_engine.cmd_open("fixture", None)
                        == "browser ready (about:blank)";
                }
            }
        }
    }
    state = {"session": "fixture", "pid": 123, "port": 9222};
    with patch.multiple(
        browser_engine,
        load_state=MagicMock(return_value=state),
        _pid_alive=MagicMock(return_value=True),
        _http_json=MagicMock()
    ), patch("subprocess.Popen") as popen {
        assert launch_browser("fixture") == state;
        popen.assert_not_called();
    }
    assert (
        Path(jaclang.__file__).resolve().parent / "cli/impl/browser_engine.impl.jac"
    ).read_bytes()
        == source;
}

with entry:__main__ {
    check_tooling();
}
