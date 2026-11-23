package bundlr

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import curl "https"

HELP :: `Bundlr ` + VERSION + `

Package a Python application as a self-contained native application.

Usage:
  bundlr                   Open the local browser interface
  bundlr [OPTIONS] <PACKAGE>
  bundlr package [OPTIONS] <PACKAGE>

Options:
  -n, --name <NAME>         Application name (default: inferred)
  -c, --command <NAME>      Application entry point (default: auto-detect)
  -k, --kind <KIND>         auto, console, or windowed
  -p, --python <VERSION>    3.12 or 3.12.13
  -t, --target <TARGET>     Repeatable, or all (default: current host)
  -o, --output <PATH>       Output directory (default: dist)
  -h, --help                Show this help
      --diagnose           Verify and repair embedded uv offline
  -V, --version             Show the Bundlr version

Targets: linux-x86_64, macos-arm64, macos-x86_64, windows-x86_64
Example: bundlr --name Black --command black --kind console black==26.5.1
`
Console_Write :: struct { file: ^os.File, bytes: []u8, done, failed: bool, references: i32 }
release_console_write :: proc(w: ^Console_Write) {
    if sync.atomic_sub(&w.references, 1) == 1 {
        delete(w.bytes, os.heap_allocator())
        free(w, os.heap_allocator())
    }
}
console_write_worker :: proc(data: rawptr) {
    w := (^Console_Write)(data)
    defer release_console_write(w)
    remaining := w.bytes
    for len(remaining) > 0 {
        n, err := os.write(w.file, remaining)
        if err != nil || n == 0 { w.failed = true; break }
        remaining = remaining[n:]
    }
    sync.atomic_store(&w.done, true)
}
console_output :: proc(b: ^Build, stream, s: string) {
    // Keep OS pipe flags unchanged. One owned chunk is written on a worker so
    // cancellation can stop waiting and reap children even if the consumer
    // never reads. A cancelled CLI exits the process, including a stalled writer.
    // Both sides retain the chunk until they are finished with it.
    context.allocator = os.heap_allocator()
    remaining := transmute([]u8)s
    for len(remaining) > 0 {
        if check_cancel(b) != nil { return }
        count := min(16384, len(remaining))
        w := new(Console_Write)
        w.file = os.stdout if stream == "stdout" else os.stderr
        w.bytes = make([]u8, count)
        copy(w.bytes, remaining[:count])
        w.references = 2
        defer release_console_write(w)
        if thread.create_and_start_with_data(w, console_write_worker, self_cleanup = true) == nil {
            release_console_write(w) // No worker owns the second reference.
            if b != nil { b.error = "Cannot start console output writer."; sync.atomic_store(&b.cancelled, true) }
            return
        }
        for !sync.atomic_load(&w.done) {
            if check_cancel(b) != nil { return }
            time.sleep(time.Millisecond)
        }
        if w.failed {
            if b != nil { b.error = "Cannot write console output."; sync.atomic_store(&b.cancelled, true) }
            return
        }
        remaining = remaining[count:]
    }
}
Signal_Watch :: struct { build: ^Build, done: bool }
signal_watch :: proc(t: ^thread.Thread) {
    w := (^Signal_Watch)(t.data)
    for !sync.atomic_load(&w.done) {
        if was_signalled() { sync.atomic_store(&w.build.cancelled, true); break }
        time.sleep(10*time.Millisecond)
    }
}
console_status :: proc(b: ^Build, status: int) -> int {
    if b.error != nil { return 1 }
    if sync.atomic_load(&b.cancelled) || was_signalled() { return 130 }
    return status
}
run_cli :: proc(input: []string) -> int {
    args := input
    if len(args) == 0 {
        if err := start_desktop(); err != nil { fmt.eprintln(err); return 1 }
        return 0
    }
    b := Build{output = console_output}
    watch := Signal_Watch{build = &b}
    t := thread.create(signal_watch)
    t.data = &watch
    thread.start(t)
    defer { sync.atomic_store(&watch.done, true); thread.join(t); thread.destroy(t) }
    if args[0] == "package" { args = args[1:] }
    if len(args) == 0 { console_output(&b, "stderr", "A PyPI requirement or HTTPS Git URL is required.\n"); return console_status(&b, 2) }
    switch args[0] {
    case "--help", "-h": console_output(&b, "stdout", HELP); return console_status(&b, 0)
    case "--version", "-V": console_output(&b, "stdout", VERSION+"\n"); return console_status(&b, 0)
    case "--diagnose":
        uv, e := resolve_uv()
        if e != nil { console_output(&b, "stderr", fmt.aprintf("%v\n", e)); return console_status(&b, 1) }
        if err := run(&b, []string{uv, "--version"}); err != nil { console_output(&b, "stderr", fmt.aprintf("%v\n", err)); return console_status(&b, 1) }
        console_output(&b, "stdout", "Runtime diagnostic passed.\n")
        return console_status(&b, 0)
    }
    r, e := parse_cli(args)
    if e != nil { console_output(&b, "stderr", fmt.aprintf("%v\n", e)); return console_status(&b, 2) }
    results, err := package_targets(&b, r)
    if err != nil {
        console_output(&b, "stderr", fmt.aprintf("%v\n", err))
        return console_status(&b, 2)
    }
    for result in results { console_output(&b, "stdout", fmt.aprintf("Created %s for %s (%s).\n", result.archivePath, result.target, result.sha256)) }
    return console_status(&b, 0)
}
main :: proc() {
    when !EMBED_UV { fmt.eprintln("Application builds require embedded uv. Use the native developer driver to prepare it."); os.exit(1) }
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil { os.exit(1) }
    context.allocator = virtual.arena_allocator(&arena)
    code: int
    if len(os.args) > 1 && os.args[1] == "--internal-exec" { code = internal_exec(os.args[2:]) }
    else {
        setup_signals()
        if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { fmt.eprintln("Cannot initialize HTTPS."); code = 1 }
        else { code = run_cli(os.args[1:]); curl.global_cleanup() }
    }
    virtual.arena_destroy(&arena)
    os.exit(code)
}
