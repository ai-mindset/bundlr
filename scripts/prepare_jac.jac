"""Apply the pinned Jac 0.39.1 regex yield fix in an isolated compiler cache."""
import hashlib;
import argparse;
import json;
import os;
import tempfile;
import jaclang;
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

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("--target", `default=host_target());
    prepare_native_runtime(parser.parse_args().target);
}
