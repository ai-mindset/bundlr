package bundlr

import "core:compress/deflate"
import "core:encoding/json"
import "core:fmt"
import "core:os"

// Developer commands can prepare the payload before it exists. Application
// builds always use the embedded, verified bytes unless explicitly disabled.
EMBED_UV :: #config(BUNDLR_EMBED_UV, true)
when EMBED_UV {
    UV_GZIP :: #load("../vendor/uv/uv.gz")
    UV_PROVENANCE :: #load("../vendor/uv/provenance.json")
}
uv_payload :: proc(include_binary := true) -> (compressed, provenance: []u8, failure: Error) {
    when EMBED_UV { return UV_GZIP, UV_PROVENANCE, nil }
    else {
        if include_binary {
            data, e := os.read_entire_file("vendor/uv/uv.gz", context.allocator)
            if e != nil { return nil, nil, "Prepare uv first." }
            compressed = data
        }
        record, re := os.read_entire_file("vendor/uv/provenance.json", context.allocator)
        if re != nil { return nil, nil, "Prepare uv provenance first." }
        return compressed, record, nil
    }
}
Provenance :: struct { version, target, executableSha256, manifestSha256: string }
cache_directory :: proc() -> string {
    if p := env("BUNDLR_CACHE_DIRECTORY"); p != "" { return p }
    when ODIN_OS == .Windows { return join(env("LOCALAPPDATA"), "Bundlr", "runtime") }
    else when ODIN_OS == .Darwin { return join(env("HOME"), "Library", "Caches", "bundlr", "runtime") }
    else {
        base := env("XDG_CACHE_HOME")
        if base == "" { base = join(env("HOME"), ".cache") }
        return join(base, "bundlr", "runtime")
    }
}
resolve_uv :: proc() -> (value: string, failure: Error) {
    _, provenance := uv_payload(false) or_return
    p: Provenance
    if json.unmarshal(provenance, &p) != nil || p.version != UV_VERSION || p.target != host_target() || p.manifestSha256 != UV_MANIFEST_SHA || len(p.executableSha256) != 64 {
        return "", "Embedded uv provenance does not match the pinned host release."
    }
    override, specified := os.lookup_env("BUNDLR_UV_EXECUTABLE", context.allocator)
    if specified {
        path, e := absolute_path(override)
        if e != nil || !matches_hash(path, p.executableSha256) { return "", "BUNDLR_UV_EXECUTABLE must match the checksum-pinned host uv binary." }
        return path, nil
    }
    dir := join(cache_directory(), UV_VERSION, host_target())
    name := "uv"
    when ODIN_OS == .Windows { name = "uv.exe" }
    path := join(dir, name)
    if !matches_hash(path, p.executableSha256) {
        compressed, _ := uv_payload() or_return
        binary: [dynamic]u8
        defer delete(binary)
        if deflate.inflate_gzip(&binary, compressed, max_output_size = 128*1024*1024) != nil { return "", "Embedded uv failed SHA-256 verification (invalid gzip)." }
        if bytes_hash(binary[:]) != p.executableSha256 { return "", "Embedded uv failed SHA-256 verification." }
        if e := mkdir(dir); e != nil { return "", e }
        stage, se := os.make_directory_temp(dir, ".uv-", context.allocator)
        if se != nil { return "", "Cannot stage uv cache repair." }
        defer os.remove_all(stage)
        candidate := join(stage, name)
        if e := write_bytes(candidate, binary[:], os.perm_number(0o755)); e != nil { return "", e }
        if rename_error := os.rename(candidate, path); rename_error != nil { return "", fmt.aprintf("Cannot repair uv cache: %v", rename_error) }
        if !matches_hash(path, p.executableSha256) { return "", "Cached uv failed SHA-256 verification." }
    }
    when ODIN_OS != .Windows {
        if os.chmod(path, os.perm_number(0o755)) != nil { return "", "Cannot set uv executable permissions." }
    }
    return path, nil
}
materialize_python :: proc(b: ^Build, target, dest: string) -> Error {
    d := distribution(target)
    url := fmt.aprintf("https://github.com/astral-sh/python-build-standalone/releases/download/20260718/cpython-%s+20260718-%s-install_only_stripped.tar.gz", PYTHON_VERSION, d.triple)
    cache := env("BUNDLR_PYTHON_CACHE_DIRECTORY")
    if cache == "" { cache = join(cache_directory(), "python") }
    path := join(cache, fmt.aprintf("%s.tar.gz", bytes_hash(transmute([]u8)fmt.aprintf("%s\n%s", url, d.sha))))
    if e := check_cancel(b); e != nil { return e }
    if !matches_hash(path, d.sha) {
        if e := mkdir(cache); e != nil { return e }
        stage, e := os.make_directory_temp(cache, ".python-", context.allocator)
        if e != nil { return "Cannot stage Python download." }
        defer os.remove_all(stage)
        candidate := join(stage, "python.tar.gz")
        if e := download(b, url, candidate); e != nil { return e }
        if !matches_hash(candidate, d.sha) { return "Python runtime failed SHA-256 verification." }
        if rename_error := os.rename(candidate, path); rename_error != nil { return "Cannot publish verified Python cache." }
    }
    return extract_verified_runtime(b, path, d.sha, dest, d.executable)
}

extract_verified_runtime :: proc(b: ^Build, archive, expected_sha, destination, executable: string) -> Error {
    if e := check_cancel(b); e != nil { return e }
    if !matches_hash(archive, expected_sha) { return "Python runtime failed SHA-256 verification." }
    if e := mkdir(destination); e != nil { return e }
    if e := run(b, []string{"tar", "-xzf", archive, "-C", destination, "--strip-components=1"}); e != nil { return e }
    info, stat_error := os.stat(join(destination, executable), context.allocator)
    if stat_error != nil || info.type != .Regular { return "Python runtime is missing its executable." }
    return nil
}
