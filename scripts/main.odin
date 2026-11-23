package main

import b "../src"
import t "../tests"
import curl "../src/https"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

COMPILER_VERSION :: "odin version dev-2026-11-nightly:9a69916"
COMPILER_REVISION :: "9a6991685ddf663956d9836602eb421e141fc443"
Error :: b.Error

check_compiler_version :: proc(path, reported: string) -> Error {
    // The executable label varies with argv[0] and platform path spelling.
    banner := b.trim(reported)
    expected := strings.trim_prefix(COMPILER_VERSION, "odin")
    if len(banner) <= len(expected) || !strings.has_suffix(banner, expected) || strings.contains_any(banner, "\r\n") {
        return fmt.aprintf("Compiler mismatch for %s: expected %s, received %s", path, COMPILER_VERSION, banner)
    }
    return nil
}
compiler :: proc() -> (value: string, failure: Error) {
    path := b.env("ODIN")
    if path == "" { path = "odin" }
    version, stderr, e := t.capture([]string{path, "version"})
    if e != nil { return "", fmt.aprintf("Cannot run Odin: %v %s", e, stderr) }
    if mismatch := check_compiler_version(path, version); mismatch != nil { return "", mismatch }
    return path, nil
}
execute :: proc(args: []string) -> Error {
    if len(args) == 0 { return "Use: prepare-uv [--prepared], build [new-output-path], check, verify [binary], acceptance [binary] [new-evidence-directory] [--all-targets], browser [binary], consume <archives>, or stamp-version." }
    switch args[0] {
    case "prepare-uv":
        if len(args) > 2 || len(args) == 2 && args[1] != "--prepared" { return "Use: prepare-uv [--prepared]." }
        return prepare_uv(len(args) == 2)
    case "build":
        if len(args) > 2 { return "Use: build [new-output-path]." }
        path := t.default_binary()
        if len(args) > 1 { path = args[1] }
        return build(path)
    case "stamp-version":
        if len(args) != 1 { return "Use: stamp-version with BUNDLR_RELEASE_TAG set." }
        return stamp_version()
    case "verify":
        if len(args) > 2 { return "Use: verify [binary]." }
        path := t.default_binary()
        if len(args) > 1 { path = args[1] }
        return t.verify(path)
    case "check":
        if len(args) != 1 { return "Use: check." }
        return check()
    case "consume":
        if len(args) != 2 { return "Use: consume <cross-built-archive-directory>." }
        return t.consume(args[1])
    case "acceptance":
        binary, evidence, all := t.default_binary(), "", false
        positional := 0
        for arg in args[1:] {
            if arg == "--all-targets" { all = true; continue }
            if strings.has_prefix(arg, "--") { return fmt.aprintf("Unknown acceptance option: %s", arg) }
            if positional == 0 { binary = arg } else if positional == 1 { evidence = arg } else { return "Too many acceptance arguments." }
            positional += 1
        }
        return t.packaging_acceptance(binary, evidence, all)
    case "browser":
        if len(args) > 2 { return "Use: browser [binary]." }
        path := t.default_binary()
        if len(args) > 1 { path = args[1] }
        return t.browser(path)
    }
    return fmt.aprintf("Unknown developer command: %s", args[0])
}
main :: proc() {
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil { os.exit(1) }
    context.allocator = virtual.arena_allocator(&arena)
    if len(os.args) > 1 && os.args[1] == "--internal-exec" { os.exit(b.internal_exec(os.args[2:])) }
    if len(os.args) > 1 && os.args[1] == "--fixture" { os.exit(t.fixture(os.args[2:])) }
    b.setup_signals()
    if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { fmt.eprintln("Cannot initialize HTTPS."); os.exit(1) }
    e := execute(os.args[1:])
    if e != nil { fmt.eprintln(e) }
    curl.global_cleanup()
    virtual.arena_destroy(&arena)
    os.exit(1 if e != nil else 0)
}
