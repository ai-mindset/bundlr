"""Prepare only checksum-verified upstream uv bytes. Runs under the developer's Jac."""
import argparse;
import hashlib;
import io;
import json;
import os;
import platform;
import re;
import shutil;
import tarfile;
import tempfile;
import zipfile;
import from pathlib { Path }
import from urllib.request { urlopen }

def:pub uv_pins -> tuple[str, str] {
    source = Path("src/platform/uv_runtime.jac").read_text();
    version = re.search(r'UV_VERSION: str = "([^"]+)"', source);
    checksum = re.search(r'UV_CHECKSUM_MANIFEST_SHA256: str = "([^"]+)"', source);
    if version is None or checksum is None {
        raise RuntimeError("Missing uv release pins.");
    }
    return (version.group(1), checksum.group(1));
}

def:pub host_target -> str {
    system = platform.system();
    machine = platform.machine().lower();
    if system == "Windows" and machine in ["amd64", "x86_64"] {
        return "windows-x86_64";
    }
    if system == "Darwin" {
        return "macos-arm64" if machine in ["arm64", "aarch64"] else "macos-x86_64";
    }
    if system == "Linux" and machine in ["amd64", "x86_64"] {
        return "linux-x86_64";
    }
    raise RuntimeError("Unsupported build host.");
}

def:pub download_bytes(url: str) -> bytes {
    with urlopen(url, timeout=60) as response {
        return response.read();
    }
}

def:pub prepare_uv(target: str) -> Path {
    triples = {
        "linux-x86_64": "x86_64-unknown-linux-gnu",
        "windows-x86_64": "x86_64-pc-windows-msvc",
        "macos-arm64": "aarch64-apple-darwin",
        "macos-x86_64": "x86_64-apple-darwin"
    };
    triple = triples[target];
    (version, manifest_hash) = uv_pins();
    base = f"https://github.com/astral-sh/uv/releases/download/{version}";
    manifest = download_bytes(base + "/sha256.sum");
    if hashlib.sha256(manifest).hexdigest() != manifest_hash {
        raise RuntimeError("uv checksum manifest failed SHA-256 verification.");
    }
    suffix = ".zip" if target == "windows-x86_64" else ".tar.gz";
    artifact = "uv-" + triple + suffix;
    checksums: dict[str, str] = {};
    for line in manifest.decode().splitlines() {
        parts = line.split();
        if len(parts) == 2 {
            checksums[parts[1].lstrip("*")] = parts[0].lower();
        }
    }
    expected = checksums[artifact];
    archive = download_bytes(base + "/" + artifact);
    if hashlib.sha256(archive).hexdigest() != expected {
        raise RuntimeError("uv release archive failed SHA-256 verification.");
    }
    name = "uv.exe" if target == "windows-x86_64" else "uv";
    binary = b"";
    if suffix == ".zip" {
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped {
            matches = [
                item
                for item in zipped.infolist()
                if not item.is_dir() and item.filename.split("/")[-1] == name
            ];
            if len(matches) != 1 {
                raise RuntimeError(
                    "uv archive must contain exactly one matching executable."
                );
            }
            binary = zipped.read(matches[0]);
        }
    } else {
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar {
            matches_tar = [
                item
                for item in tar.getmembers()
                if item.isfile() and item.name.split("/")[-1] == name
            ];
            if len(matches_tar) != 1 {
                raise RuntimeError(
                    "uv archive must contain exactly one matching executable."
                );
            }
            handle = tar.extractfile(matches_tar[0]);
            if handle is None {
                raise RuntimeError("uv executable could not be extracted.");
            }
            with handle {
                binary = handle.read();
            }
        }
    }
    directory = Path("vendor/uv");
    directory.mkdir(parents=True, exist_ok=True);
    checksum = hashlib.sha256(binary).hexdigest();
    with tempfile.TemporaryDirectory(dir=directory) as staging {
        staged = Path(staging) / name;
        staged.write_bytes(binary);
        staged.chmod(0o755);
        staged.replace(directory / name);
    }
    (directory / "uv.sha256").write_text(checksum + "\n");
    metadata = {
        "version": version,
        "target": target,
        "url": base + "/" + artifact,
        "manifestSha256": manifest_hash,
        "archiveSha256": expected,
        "executableSha256": checksum
    };
    (directory / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n");
    for licence in ["LICENSE-MIT", "LICENSE-APACHE"] {
        (directory / licence).write_bytes(
            download_bytes(
                f"https://raw.githubusercontent.com/astral-sh/uv/{version}/{licence}"
            )
        );
    }
    print(f"Prepared uv {version} for {target} ({checksum}).");
    return directory / name;
}

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("--target", `default=host_target());
    prepare_uv(parser.parse_args().target);
}
