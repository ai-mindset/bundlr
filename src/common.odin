package bundlr

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

VERSION :: "0.2.0-dev"
UV_VERSION :: "0.13.9"
UV_MANIFEST_SHA :: "5679a011d4663f7d394463bbe057de440047424c09b84ff21fc1a2c5104f1a8c"
PYTHON_VERSION :: "3.12.13"
Error :: union {string}

// A build owns an arena. No references into it survive completion. Only cancellation
// and the output sink cross threads; the sink applies backpressure synchronously.
Build :: struct {
    cancelled: bool,
    output: proc(b: ^Build, stream, text: string),
    user: rawptr,
    error: Error,
}
check_cancel :: proc(b: ^Build) -> Error {
    if b != nil && sync.atomic_load(&b.cancelled) { return "Cancelled by the user." }
    return nil
}
log :: proc(b: ^Build, stream, text: string) {
    if b != nil && b.output != nil { b.output(b, stream, text) }
}
join :: proc(parts: ..string) -> string { v, _ := filepath.join(parts); return v }
// Unlike POSIX filepath.abs, this also accepts missing output paths and keeps
// the final symlink intact for lstat collision and checksum checks.
absolute_path :: proc(path: string) -> (value: string, failure: Error) {
    when ODIN_OS == .Windows {
        full, e := filepath.abs(path)
        if e != nil { return "", "Cannot resolve absolute path." }
        return full, nil
    } else {
        if filepath.is_abs(path) { return path, nil }
        directory, e := os.get_working_directory(context.allocator)
        if e != nil { return "", "Cannot read working directory." }
        return join(directory, path), nil
    }
}
env :: proc(key: string) -> string { return os.get_env(key, context.allocator) }
text :: proc(path: string) -> (value: string, failure: Error) {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil { return "", fmt.aprintf("Cannot read %s: %v", path, err) }
    return string(data), nil
}
write_bytes :: proc(path: string, data: []u8, mode := os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}) -> Error {
    f, err := os.open(path, {.Write, .Create, .Excl}, mode)
    if err != nil { return fmt.aprintf("Cannot create %s: %v", path, err) }
    defer os.close(f)
    n, we := os.write(f, data)
    if we != nil || n != len(data) { return fmt.aprintf("Cannot finish writing %s", path) }
    return nil
}
write_text :: proc(path, data: string, mode := os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}) -> Error {
    return write_bytes(path, transmute([]u8)data, mode)
}
mkdir :: proc(path: string) -> Error {
    if err := os.make_directory_all(path, os.perm_number(0o755)); err != nil {
        info, stat_error := os.stat(path, context.allocator)
        if err != .Exist || stat_error != nil || info.type != .Directory { return fmt.aprintf("Cannot create directory %s: %v", path, err) }
    }
    return nil
}
absent :: proc(path: string) -> Error {
    _, err := os.lstat(path, context.allocator)
    if err == .Not_Exist { return nil }
    if err != nil { return fmt.aprintf("Cannot inspect %s: %v", path, err) }
    return fmt.aprintf("Refusing to overwrite %s", path)
}
file_hash :: proc(path: string) -> (value: string, failure: Error) {
    digest, err := hash.hash_file_by_name(.SHA256, path)
    if err != .None { return "", fmt.aprintf("Cannot hash %s", path) }
    defer delete(digest)
    return string(hex.encode(digest)), nil
}
bytes_hash :: proc(data: []u8) -> string {
    digest := hash.hash_bytes(.SHA256, data)
    defer delete(digest)
    return string(hex.encode(digest))
}
matches_hash :: proc(path, expected: string) -> bool {
    info, e := os.lstat(path, context.allocator)
    if e != nil || info.type != .Regular { return false }
    actual, err := file_hash(path)
    return err == nil && actual == expected
}
json_text :: proc(value: any) -> string {
    data, err := json.marshal(value)
    assert(err == nil)
    return string(data)
}
trim :: proc(s: string) -> string { return strings.trim_space(s) }
contains_control :: proc(s: string) -> bool {
    for c in s { if c < 32 || c == 127 { return true } }
    return false
}
replace :: proc(s, old, new: string) -> string { value, _ := strings.replace_all(s, old, new); return value }
