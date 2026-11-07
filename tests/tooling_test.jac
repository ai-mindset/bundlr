"""Developer-tool regressions; application behavior is exercised by native_test.jac."""
import hashlib;
import json;
import os;
import jaclang;
import subprocess;
import tempfile;
import from pathlib { Path }
import from unittest.mock { patch }
import from scripts.build { audit_runtime, copy_libraries }
import from scripts.prepare_jac { patch_windows_regex, prepare_native_runtime }

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
    check_macos_audit();
    check_windows_regex_patch();
    print(
        "Developer helper reuse, preparation CLI, macOS audit and compiler patch contracts passed."
    );
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

with entry:__main__ {
    check_tooling();
}
