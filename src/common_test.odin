package bundlr

import "core:mem/virtual"
import "core:os"
import "core:testing"

@(test)
absolute_paths_keep_missing_outputs_and_symlinks :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    root, e := os.make_directory_temp("", "bundlr-path-test-", context.allocator)
    testing.expect(t, e == nil)
    if e != nil { return }
    defer os.remove_all(root)
    missing := join(root, "missing-output")
    path, failure := absolute_path(missing)
    testing.expect(t, failure == nil && path == missing && absent(path) == nil)
    when ODIN_OS != .Windows {
        alias := join(root, "symlink")
        testing.expect(t, os.symlink(missing, alias) == nil)
        resolved, re := absolute_path(alias)
        testing.expect(t, re == nil && resolved == alias && absent(resolved) != nil)
    }
}
