package main

import "core:mem/virtual"
import "core:testing"

@(test)
compiler_banner_preserves_revision_and_accepts_invocation_paths :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    for example in ([]struct { path, banner: string }{
        {"odin", "odin version dev-2026-11-nightly:9a69916\n"},
        {"/tmp/compiler version with spaces/odin", "/tmp/compiler version with spaces/odin version dev-2026-11-nightly:9a69916\n"},
        {`C:\compiler with spaces\odin.exe`, "C:\\compiler with spaces\\odin.exe version dev-2026-11-nightly:9a69916\r\n"},
        {"/c/compiler/odin.exe", "C:\\compiler\\odin.exe version dev-2026-11-nightly:9a69916\r\n"},
    }) {
        testing.expect(t, check_compiler_version(example.path, example.banner) == nil)
    }
    for banner in ([]string{
        "odin version dev-2026-11-nightly:0000000",
        "odin version dev-2026-12-nightly:9a69916",
        "odin version dev-2026-11:9a69916",
        " version dev-2026-11-nightly:9a69916",
        "unexpected output\nodin version dev-2026-11-nightly:9a69916",
        "odin version dev-2026-11-nightly:9a69916 unexpected",
        "",
    }) {
        testing.expect(t, check_compiler_version("odin", banner) != nil)
    }
}
