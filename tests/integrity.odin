#+feature dynamic-literals
package acceptance

import b "../src"
import "core:compress/deflate"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

verify :: proc(requested: string) -> Error {
    binary := b.absolute_path(requested) or_return
    base := temporary() or_return
    defer os.remove_all(base)
    cache := b.join(base, "cache")
    env := environment(map[string]string{"PATH" = "", "BUNDLR_CACHE_DIRECTORY" = cache}, []string{"BUNDLR_UV_EXECUTABLE"})
    out, stderr, help_error := capture([]string{binary, "--help"}, env)
    if help_error != nil || !strings.contains(out, "--command") { return fmt.aprintf("Compiled help failed: %s%s", out, stderr) }
    version, _, ve := capture([]string{binary, "--version"}, env)
    if ve != nil || b.trim(version) != b.VERSION { return "Compiled version differs from source." }
    invalid := [][]string{{"unpinned"}, {"--python", "3.13", "demo==1"}, {"--target", "invalid", "demo==1"}, {"--name", "../invalid", "demo==1"}, {"package"}}
    for args in invalid {
        command := make([dynamic]string)
        append(&command, binary, "--output", b.join(base, "invalid-output"))
        append(&command, ..args)
        _, _, e := capture(command[:], env)
        if e == nil { return "Compiled CLI accepted an invalid request." }
    }
    if b.absent(b.join(base, "invalid-output")) != nil { return "Invalid input created output." }
    if e := command([]string{binary, "--diagnose"}, env); e != nil { return e }
    record: b.Provenance
    metadata := read_bytes("vendor/uv/provenance.json") or_return
    if json.unmarshal(metadata, &record) != nil || record.version != b.UV_VERSION || record.manifestSha256 != b.UV_MANIFEST_SHA { return "Prepared uv provenance does not match source pins." }
    name := "uv.exe" when ODIN_OS == .Windows else "uv"
    cached := b.join(cache, b.UV_VERSION, b.host_target(), name)
    if !b.matches_hash(cached, record.executableSha256) { return "Extracted uv checksum differs." }
    corrupt := "corrupt cached uv"
    if e := overwrite(cached, transmute([]u8)corrupt); e != nil { return e }
    if e := command([]string{binary, "--diagnose"}, env); e != nil { return e }
    if !b.matches_hash(cached, record.executableSha256) { return "Corrupt uv cache was not repaired." }
    when ODIN_OS != .Windows {
        if os.chmod(cached, os.perm_number(0o644)) != nil { return "Cannot set test cache permissions." }
        if e := command([]string{binary, "--diagnose"}, env); e != nil { return e }
        info, e := os.stat(cached, context.allocator)
        if e != nil || info.mode&os.Permissions_Execute_All == {} { return "uv executable permissions were not repaired." }
    }
    untrusted := b.join(base, "untrusted-override")
    if e := b.write_text(untrusted, "untrusted bytes"); e != nil { return e }
    override_env := environment(map[string]string{"PATH" = "", "BUNDLR_UV_EXECUTABLE" = untrusted})
    _, rejected, rejection := capture([]string{binary, "--diagnose"}, override_env)
    if rejection == nil || !strings.contains(rejected, "checksum-pinned") { return "Unverified uv override was accepted." }
    when ODIN_OS != .Windows {
        if os.remove(cached) != nil || os.symlink(untrusted, cached) != nil { return "Cannot create owned cache symlink." }
        if e := command([]string{binary, "--diagnose"}, env); e != nil { return e }
        if !b.matches_hash(cached, record.executableSha256) { return "Symlinked uv cache was not repaired." }
        original := b.text(untrusted) or_return
        if original != "untrusted bytes" { return "uv repair followed a symlink." }
        // A filename containing no slash must execute the same file we hashed.
        // The child changes directory through the native fixture trampoline.
        directory, shadow := b.join(base, "override"), b.join(base, "shadow")
        if e := b.mkdir(directory); e != nil { return e }
        if e := b.mkdir(shadow); e != nil { return e }
        bytes := read_bytes(cached) or_return
        if e := b.write_bytes(b.join(directory, "uv"), bytes, os.perm_number(0o755)); e != nil { return e }
        if e := b.write_text(b.join(shadow, "uv"), "#!/bin/sh\nprintf 'unverified shadow uv\\n'\n", os.perm_number(0o755)); e != nil { return e }
        specific := environment(map[string]string{"PATH" = shadow, "BUNDLR_UV_EXECUTABLE" = "uv"})
        result, error_text, failure := capture([]string{self(), "--fixture", "cwd", directory, binary, "--diagnose"}, specific)
        if failure != nil || !strings.contains(result, fmt.aprintf("uv %s ", b.UV_VERSION)) || strings.contains(result, "unverified shadow") { return fmt.aprintf("Verified uv path was not executed: %s%s", result, error_text) }
    }
    contents := read_bytes(binary) or_return
    payload := read_bytes("vendor/uv/uv.gz") or_return
    offset := strings.index(string(contents), string(payload))
    if offset < 0 { return "Cannot locate embedded uv for integrity check." }
    for &byte in contents[offset:offset+len(payload)] { byte = 0 }
    replacement: [dynamic]u8
    fake_payload := "untrusted embedded uv"
    if deflate.deflate_gzip(&replacement, transmute([]u8)fake_payload) != nil { return "Cannot prepare tamper fixture." }
    if len(replacement) > len(payload) { return "Tamper fixture exceeds embedded payload." }
    copy(contents[offset:], replacement[:])
    damaged := b.join(base, "damaged.exe" when ODIN_OS == .Windows else "damaged")
    if e := b.write_bytes(damaged, contents, os.perm_number(0o755)); e != nil { return e }
    when ODIN_OS == .Darwin { if e := command([]string{"codesign", "--force", "--sign", "-", damaged}); e != nil { return e } }
    damaged_env := environment(map[string]string{"PATH" = "", "BUNDLR_CACHE_DIRECTORY" = b.join(base, "fresh-cache")}, []string{"BUNDLR_UV_EXECUTABLE"})
    _, message, tamper_error := capture([]string{damaged, "--diagnose"}, damaged_env)
    if tamper_error == nil || !strings.contains(message, "SHA-256 verification") { return "Tampered embedded uv was not rejected." }
    fmt.println("Compiled CLI, offline uv integrity, repair, override and tamper checks passed.")
    return nil
}
