"""Build a runnable host developer workspace; portable releases use build.jac."""
import argparse;
import hashlib;
import json;
import subprocess;
import from pathlib { Path }
import from scripts.build {
    native_dependencies,
    copy_libraries,
    prepare_resources,
    compile_native
}
import from scripts.prepare_uv { host_target, prepare_uv }

def:pub check_development_output(output: Path) {
    for name in ["bundlr", "bundlr.exe", "bundlr-manifest.json"] {
        if (output / name).exists() {
            raise RuntimeError(
                "Refusing to modify a completed artifact: " + str(output)
            );
        }
    }
    if not (output / ".bundlr-development").is_file() {
        for name in ["data", "licenses", "native-dependencies.json"] {
            if (output / name).exists() {
                raise RuntimeError(
                    "Choose an empty developer output directory: " + str(output)
                );
            }
        }
    }
}

with entry:__main__ {
    parser = argparse.ArgumentParser(description=__doc__);
    parser.add_argument("--output", `default="dist");
    parser.add_argument("--native-libs");
    parser.add_argument("--prepared-uv", action="store_true");
    args = parser.parse_args();
    output = Path(args.output).resolve();
    check_development_output(output);
    lock = json.loads(Path("build-lock.json").read_text()) as dict[str, object];
    target = host_target();
    libraries = Path(args.native_libs).resolve()
        if args.native_libs
        else native_dependencies(target, lock);
    uv = Path("vendor/uv" + ("/uv.exe" if target == "windows-x86_64" else "/uv"));
    if not args.prepared_uv {
        uv = prepare_uv(target);
    }
    expected = Path("vendor/uv/uv.sha256").read_text().strip();
    if hashlib.sha256(uv.read_bytes()).hexdigest() != expected {
        raise RuntimeError("Prepared uv failed SHA-256 verification.");
    }
    output.mkdir(parents=True, exist_ok=True);
    (output / ".bundlr-development").write_text(
        "Developer workspace; not production release evidence.\n"
    );
    copy_libraries(libraries, output, lock, False, target);
    prepare_resources(output, uv, lock, True);
    binary = output / ("main.exe" if target == "windows-x86_64" else "main");
    compile_native("src/main.jac", binary, target);
    if target == "windows-x86_64" {
        compile_native(
            "src/platform/child_runner.jac", output / "bundlr-child.exe", target
        );
    }
    for option in ["--help", "--diagnose"] {
        subprocess.run([str(binary), option], check=True);
    }
    print("Runnable developer build: " + str(binary));
}
