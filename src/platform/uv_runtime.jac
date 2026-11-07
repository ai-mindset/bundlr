import os;
import sys;
import gzip;
import hashlib;
comptime import from jaclang.comptime { embed_file }
import from src.domain.request { current_target }
import from src.platform.files {
    join_path,
    parent_path,
    native_path,
    read_bytes,
    file_sha256,
    stat_path,
    make_dirs,
    temp_dir,
    write_bytes,
    rename_file,
    remove_tree,
    chmod_file
}

glob:pub UV_VERSION: str = "0.11.16",
     UV_CHECKSUM_MANIFEST_SHA256: str = "8ef7fe76d67be3330e18e8d6ecbbb68f7a1ae46fe31198008170e911ad025c6a";

comptime UV_SHA256: str = embed_file("../../vendor/uv/uv.sha256");

def uv_filename -> str {
    if current_target() == "windows-x86_64" {
        return "uv.exe";
    }
    return "uv";
}

def required_environment(name: str) -> str {
    value = os.getenv(name);
    if value is None or value == "" {
        raise RuntimeError(f"Required environment variable {name} is not set.");
    }
    return value;
}

def cache_base -> str {
    configured = os.getenv("BUNDLR_CACHE_DIRECTORY");
    if configured is not None and configured != "" {
        return configured;
    }
    if sys.platform == "win32" {
        return join_path(required_environment("LOCALAPPDATA"), "Bundlr/runtime");
    }
    if sys.platform == "darwin" {
        return join_path(required_environment("HOME"), "Library/Caches/bundlr/runtime");
    }
    xdg = os.getenv("XDG_CACHE_HOME");
    if xdg is None or xdg == "" {
        xdg = join_path(required_environment("HOME"), ".cache");
    }
    return join_path(xdg, "bundlr/runtime");
}

def:pub resolve_uv -> str {
    configured_uv = os.getenv("BUNDLR_UV_EXECUTABLE");
    if configured_uv is not None {
        if not stat_path(configured_uv).is_file()
            or file_sha256(configured_uv) != UV_SHA256.strip() {
            raise RuntimeError(
                "BUNDLR_UV_EXECUTABLE must match the checksum-pinned host uv binary."
            );
        }
        return configured_uv;
    }
    cache = join_path(cache_base(), UV_VERSION + "/" + current_target());
    destination = join_path(cache, uv_filename());
    info = stat_path(destination);
    if info.is_file() and file_sha256(destination) == UV_SHA256.strip() {
        if sys.platform != "win32" and (info.mode & 73) == 0 {
            chmod_file(destination, 493);
        }
        return destination;
    }
    payload = join_path(parent_path(native_path(True)), "data/uv.gz");
    if not stat_path(payload).is_file() {
        raise RuntimeError(
            "Bundled uv is missing; keep the complete portable Bundlr directory together."
        );
    }
    binary = gzip.decompress(read_bytes(payload));
    if hashlib.sha256(binary).hexdigest() != UV_SHA256.strip() {
        raise RuntimeError("Bundled uv failed SHA-256 verification.");
    }
    make_dirs(cache);
    staging = temp_dir(cache, ".uv-");
    try {
        staged_binary = join_path(staging, uv_filename());
        write_bytes(staged_binary, binary);
        chmod_file(staged_binary, 493);
        rename_file(staged_binary, destination);
        if file_sha256(destination) != UV_SHA256.strip() {
            raise RuntimeError("Cached uv failed SHA-256 verification.");
        }
        return destination;
    } finally {
        remove_tree(staging);
    }
}
