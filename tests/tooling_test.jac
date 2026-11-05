"""Developer-tool regressions; application behavior is exercised by native_test.jac."""
import hashlib;
import json;
import os;
import subprocess;
import tempfile;
import from pathlib { Path }
import from scripts.build { copy_libraries }

def:pub check_tooling {
    lock = json.loads(Path("build-lock.json").read_text());
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
    print("Developer helper reuse and preparation CLI contracts passed.");
}

with entry:__main__ {
    check_tooling();
}
