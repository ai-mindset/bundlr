"""Build contract tests with the release's native libraries, then run on the host."""
import argparse;
import json;
import shutil;
import subprocess;
import tempfile;
import from pathlib { Path }
import from scripts.prepare_uv { host_target }
import from scripts.build { compile_native, copy_libraries }
import from tests.tooling_test { check_tooling }

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("--target", `default=host_target());
    parser.add_argument("--native-libs", required=True);
    parser.add_argument("--development-libs", action="store_true");
    parser.add_argument("--output", `default=".build/tests");
    args = parser.parse_args();
    check_tooling();
    output = Path(args.output).resolve();
    output.mkdir(parents=True, exist_ok=True);
    lock = json.loads(Path("build-lock.json").read_text()) as dict[str, object];
    copy_libraries(
        Path(args.native_libs).resolve(),
        output,
        lock,
        args.development_libs,
        args.target
    );
    suffix = ".exe" if args.target == "windows-x86_64" else "";
    if args.target == "windows-x86_64" {
        compile_native(
            "src/platform/child_runner.jac", output / "bundlr-child.exe", args.target
        );
    }
    for (source, name) in [
        ("tests/process_fixture.jac", "process-fixture"),
        ("tests/acceptance.jac", "acceptance-test"),
        ("tests/native_test.jac", "native-test")
    ] {
        compile_native(source, output / (name + suffix), args.target);
    }
    if args.target == host_target() {
        with tempfile.TemporaryDirectory(prefix="bundlr-tests-") as directory {
            subprocess.run(
                [str(output / ("native-test" + suffix)), directory], check=True
            );
        }
    }
}
