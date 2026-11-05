"""Build portable native releases. Development library overrides are explicitly labelled."""
import argparse;
import gzip;
import io;
import ctypes;
import hashlib;
import json;
import os;
import platform;
import re;
import shutil;
import subprocess;
import sys;
import tarfile;
import tempfile;
import zipfile;
import from pathlib { Path }
import from scripts.prepare_uv { host_target, prepare_uv, uv_pins, download_bytes }
import from scripts.build_ui { build_ui }

glob ROOT: Path = Path.cwd();

def run(args: list[str], cwd: Path | None = None) {
    subprocess.run(args, cwd=cwd, check=True);
}

def native_dependencies(target: str, lock: dict[str, object]) -> Path {
    triplets = {
        "linux-x86_64": "bundlr-x64-linux",
        "windows-x86_64": "bundlr-x64-windows",
        "macos-arm64": "bundlr-arm64-osx",
        "macos-x86_64": "bundlr-x64-osx"
    };
    if target != host_target() {
        raise RuntimeError(
            "Cross-builds require --native-libs produced by that target's native-dependency CI job."
        );
    }
    checkout = ROOT / ".build/vcpkg";
    baseline = str(lock["vcpkgBaseline"]);
    if not checkout.exists() {
        checkout.parent.mkdir(parents=True, exist_ok=True);
        run(["git", "clone", "https://github.com/microsoft/vcpkg.git", str(checkout)]);
    }
    run(["git", "checkout", "--detach", baseline], checkout);
    if os.name == "nt" {
        run(["cmd", "/c", str(checkout / "bootstrap-vcpkg.bat"), "-disableMetrics"]);
    } else {
        run(["sh", str(checkout / "bootstrap-vcpkg.sh"), "-disableMetrics"]);
    }
    build = ROOT / ".build/native" / target;
    run(
        [
            "cmake",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(build),
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_TOOLCHAIN_FILE="
                + str(checkout / "scripts/buildsystems/vcpkg.cmake"),
            "-DVCPKG_MANIFEST_DIR=" + str(ROOT),
            "-DVCPKG_OVERLAY_TRIPLETS=" + str(ROOT / "scripts/triplets"),
            "-DVCPKG_TARGET_TRIPLET=" + triplets[target]
        ]
    );
    run(["cmake", "--build", str(build), "--config", "Release"]);
    return build / "portable-libs";
}

def:pub copy_libraries(
    source: Path,
    destination: Path,
    lock: dict[str, object],
    development: bool,
    target: str
) {
    inventory_path = source / "native-dependencies.json";
    if not development {
        inventory = json.loads(inventory_path.read_text());
        if inventory["target"] != target {
            raise RuntimeError("Native libraries belong to another target.");
        }
        if inventory["vcpkgBaseline"] != lock["vcpkgBaseline"] {
            raise RuntimeError(
                "Native dependency baseline does not match build-lock.json."
            );
        }
        for item in inventory["libraries"] {
            if Path(item["name"]).name != item["name"] {
                raise RuntimeError("Invalid native dependency inventory path.");
            }
            if hashlib.sha256((source / item["name"]).read_bytes()).hexdigest()
                != item["sha256"] {
                raise RuntimeError(
                    "Native dependency checksum mismatch: " + item["name"]
                );
            }
        }
    }
    for path in source.iterdir() {
        if path.is_file()
            and (".so" in path.name or path.suffix in [".dll", ".dylib"]) {
            # Copy developer symlinks as bytes; production keeps relative SONAME symlinks.
            if path.is_symlink() and not development {
                staged_link = destination / path.name;
                if staged_link.is_file() or staged_link.is_symlink() {
                    staged_link.unlink();
                }
                staged_link.symlink_to(Path(os.readlink(path)).name);
            } else {
                shutil.copy2(path, destination / path.name);
            }
        }
    }
    if inventory_path.exists() {
        shutil.copy2(inventory_path, destination / "native-dependencies.json");
    }
    if (source / "licenses").exists() {
        shutil.copytree(
            source / "licenses", destination / "licenses/native", dirs_exist_ok=True
        );
    }
}

def:pub compile_native(source: str, binary: Path, target: str) {
    triples = {
        "linux-x86_64": "x86_64-unknown-linux-gnu",
        "windows-x86_64": "x86_64-pc-windows-msvc",
        "macos-arm64": "aarch64-apple-darwin",
        "macos-x86_64": "x86_64-apple-darwin"
    };
    result = subprocess.run(
        [
            "jac",
            "build",
            "--native",
            source,
            "--target-triple",
            triples[target],
            "-o",
            str(binary)
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    );
    print(result.stdout);
    if result.returncode != 0 or "demoting " in result.stdout or not binary.is_file() {
        raise RuntimeError(
            "Native compilation failed or attempted a Python fallback: " + source
        );
    }
    # Compiler layout evidence is useful to developers, but contains build paths.
    Path(str(binary) + ".layout.json").unlink(missing_ok=True);
}

def audit_runtime(directory: Path, target: str) {
    if target != host_target() {
        return;
    }
    binaries = [
        path
        for path in directory.iterdir()
        if path.is_file()
            and (path.name == "bundlr" or ".so" in path.name or path.suffix == ".dylib")
    ];
    for binary in binaries {
        if target == "linux-x86_64" {
            linked = subprocess.check_output(["ldd", str(binary)], text=True);
            for line in linked.splitlines() {
                if "not found" in line {
                    raise RuntimeError("Missing portable dependency: " + line);
                }
                if "=> /" not in line {
                    continue;
                }
                path = Path(line.split("=>", 1)[1].strip().split(" ", 1)[0]).resolve();
                if path.parent == directory.resolve() {
                    continue;
                }
                if re.fullmatch(
                    r"lib(c|m|pthread|rt|dl|resolv|util)\.so\.[0-9]+", path.name
                )
                    is None {
                    raise RuntimeError("Release depends on a builder library: " + line);
                }
            }
        } elif target.startswith("macos-") {
            linked = subprocess.check_output(["otool", "-L", str(binary)], text=True);
            for line in linked.splitlines()[1:] {
                name = line.strip().split(" ", 1)[0];
                if name.startswith("/usr/lib/")
                    or name.startswith("/System/Library/") {
                    continue;
                }
                if name.startswith("@loader_path/")
                    and (directory / name[len("@loader_path/"):]).exists() {
                    continue;
                }
                raise RuntimeError(
                    "Release dependency is not relative or provided by macOS: " + name
                );
            }
        }
    }
}

def size_report(
    directory: Path,
    archive: Path,
    target: str,
    development: bool,
    lock: dict[str, object]
) -> dict[str, str | int | bool] {
    executable = directory / ("bundlr.exe" if target == "windows-x86_64" else "bundlr");
    total = sum(
        path.stat().st_size
        for path in directory.rglob("*")
        if path.is_file()
    );
    libraries = sum(
        path.stat().st_size
        for path in directory.iterdir()
        if path.is_file() and (".so" in path.name or path.suffix in [".dylib", ".dll"])
    );
    measurements = {
        "target": target,
        "executableBytes": executable.stat().st_size,
        "archiveBytes": archive.stat().st_size,
        "unpackedBytes": total,
        "uvCompressedBytes": (directory / "data/uv.gz").stat().st_size,
        "uvExpandedBytes": len(
            gzip.decompress((directory / "data/uv.gz").read_bytes())
        ),
        "nativeLibraryBytes": libraries,
        "developmentLibraries": development,
        "jacVersion": str(lock["jacVersion"]),
        "vcpkgBaseline": str(lock["vcpkgBaseline"])
    };
    limit = int(lock["maximumArtifactBytes"] as int);
    if executable.stat().st_size >= limit or archive.stat().st_size >= limit {
        raise RuntimeError(
            "The complete release exceeds the 50 MiB budget: "
                + json.dumps(measurements)
        );
    }
    return measurements;
}

def prepare_ca(portable: Path, lock: dict[str, object], development: bool) {
    if development and Path("/etc/ssl/certs/ca-certificates.crt").exists() {
        shutil.copy2(
            "/etc/ssl/certs/ca-certificates.crt", portable / "data/cacert.pem"
        );
        return;
    }
    wheel = download_bytes(str(lock["caBundleWheelUrl"]));
    if hashlib.sha256(wheel).hexdigest() != lock["caBundleWheelSha256"] {
        raise RuntimeError("CA bundle wheel failed SHA-256 verification.");
    }
    with zipfile.ZipFile(io.BytesIO(wheel)) as archive {
        (portable / "data/cacert.pem").write_bytes(archive.read("certifi/cacert.pem"));
        licences = [
            name
            for name in archive.namelist()
            if name.endswith("/LICENSE")
        ];
        if len(licences) != 1 {
            raise RuntimeError("CA bundle licence is missing.");
        }
        directory = portable / "licenses/certifi";
        directory.mkdir(parents=True, exist_ok=True);
        (directory / "LICENSE").write_bytes(archive.read(licences[0]));
        (directory / "SOURCE.txt").write_text(
            str(lock["caBundleWheelUrl"])
                + "\nSHA256 "
                + str(lock["caBundleWheelSha256"])
                + "\n"
        );
    }
}

def publish_directory(source: Path, destination: Path) {
    if os.name == "nt" {
        os.rename(source, destination);
        return;
    }
    libc = ctypes.CDLL(None, use_errno=True);
    if sys.platform == "darwin" {
        rename = libc.renamex_np;
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint];
        status = rename(os.fsencode(source), os.fsencode(destination), 4);
    } else {
        rename = libc.renameat2;
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint
        ];
        status = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1);
    }
    if status != 0 {
        raise OSError(
            ctypes.get_errno(), "Exclusive release publication failed", str(destination)
        );
    }
}

def:pub build(args: argparse.Namespace) {
    lock = json.loads((ROOT / "build-lock.json").read_text()) as dict[str, object];
    compiler = shutil.which("jac");
    if compiler is None {
        raise RuntimeError("jac is not on PATH.");
    }
    version = subprocess.check_output([compiler, "--version"], text=True);
    if not version.startswith("jac " + str(lock["jacVersion"]) + " ") {
        raise RuntimeError("Use the Jac version pinned in build-lock.json.");
    }
    target: str = args.target;
    development: bool = args.development_libs is not None;
    dependencies: Path;
    if development {
        dependencies = Path(args.development_libs).resolve();
    } elif args.native_libs {
        dependencies = Path(args.native_libs).resolve();
    } else {
        dependencies = native_dependencies(target, lock);
    }
    executable_name = "uv.exe" if target == "windows-x86_64" else "uv";
    uv_binary = ROOT / "vendor/uv" / executable_name;
    if not args.prepared_uv {
        uv_binary = prepare_uv(target);
    }
    expected_uv = (ROOT / "vendor/uv/uv.sha256").read_text().strip();
    if hashlib.sha256(uv_binary.read_bytes()).hexdigest() != expected_uv {
        raise RuntimeError("Prepared uv failed SHA-256 verification.");
    }
    output = Path(args.output).resolve();
    output.mkdir(parents=True, exist_ok=True);
    name = ("bundlr-dev-" if development else "bundlr-") + target;
    destination = output / name;
    extension = ".zip" if target == "windows-x86_64" else ".tar.gz";
    archive = output / (name + extension);
    if destination.exists()
        or archive.exists()
        or Path(str(archive) + ".sha256").exists() {
        raise RuntimeError("Refusing to overwrite an existing portable release.");
    }
    with tempfile.TemporaryDirectory(
        prefix=".bundlr-release-", dir=output
    ) as staging_name {
        staging = Path(staging_name);
        portable = staging / name;
        portable.mkdir();
        copy_libraries(dependencies, portable, lock, development, target);
        data = portable / "data";
        build_ui(data);
        prepare_ca(portable, lock, development);
        (data / "uv.gz").write_bytes(
            gzip.compress(uv_binary.read_bytes(), compresslevel=9, mtime=0)
        );
        shutil.copy2(ROOT / "LICENSE", portable / "LICENSE");
        shutil.copytree(ROOT / "vendor/licenses", portable / "licenses/compiler");
        for licence in ["LICENSE-MIT", "LICENSE-APACHE", "provenance.json"] {
            path = ROOT / "vendor/uv" / licence;
            if path.exists() {
                uv_licences = portable / "licenses/uv";
                uv_licences.mkdir(parents=True, exist_ok=True);
                shutil.copy2(path, uv_licences / licence);
            } elif not development {
                raise RuntimeError(
                    "Verified uv provenance/licences are missing; prepare uv again."
                );
            }
        }
        binary = portable / ("bundlr.exe" if target == "windows-x86_64" else "bundlr");
        compile_native("src/main.jac", binary, target);
        if target == "windows-x86_64" {
            compile_native(
                "src/platform/child_runner.jac", portable / "bundlr-child.exe", target
            );
        }
        if not development {
            audit_runtime(portable, target);
        }
        if target == host_target() {
            run([str(binary), "--help"]);
            run([str(binary), "--diagnose"]);
        }
        staged_archive = staging / archive.name;
        if extension == ".zip" {
            with zipfile.ZipFile(
                staged_archive,
                "x",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=9,
                allowZip64=False
            ) as zipped {
                for path in sorted(portable.rglob("*")) {
                    if path.is_file() {
                        zipped.write(path, str(path.relative_to(staging)));
                    }
                }
            }
        } else {
            with tarfile.open(staged_archive, "x:gz") as tar {
                tar.add(portable, arcname=name);
            }
        }
        measurements = size_report(portable, staged_archive, target, development, lock);
        checksum = hashlib.sha256(staged_archive.read_bytes()).hexdigest();
        checksum_file = staging / (archive.name + ".sha256");
        checksum_file.write_text(checksum + "  " + archive.name + "\n");
        size_file = staging / (archive.name + ".size.json");
        size_file.write_text(json.dumps(measurements, indent=2) + "\n");
        published: list[Path] = [];
        directory_published = False;
        try {
            publish_directory(portable, destination);
            directory_published = True;
            for staged in [staged_archive, checksum_file, size_file] {
                final_path = output / staged.name;
                os.link(staged, final_path);
                published.append(final_path);
            }
        } except Exception {
            for path in reversed(published) {
                path.unlink();
            }
            if directory_published {
                shutil.rmtree(destination);
            }
            raise;
        }
        print(json.dumps(measurements, indent=2));
    }
}

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("--target", `default=host_target());
    parser.add_argument("--output", `default="dist");
    parser.add_argument("--native-libs");
    parser.add_argument("--development-libs");
    parser.add_argument("--prepared-uv", action="store_true");
    build(parser.parse_args());
}
