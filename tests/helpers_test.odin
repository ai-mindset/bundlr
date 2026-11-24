package acceptance

import b "../src"
import "core:mem/virtual"
import "core:os"
import "core:testing"

@(test)
overwrite_truncates_existing_files_and_rejects_missing_paths :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    root, e := temporary()
    if !testing.expect(t, e == nil) { return }
    defer os.remove_all(root)
    path := b.join(root, "owned-file")
    testing.expect(t, overwrite(path, nil) != nil)
    testing.expect(t, b.absent(path) == nil)
    if !testing.expect(t, b.write_text(path, "original contents") == nil) { return }
    for value in ([]string{"short", "a longer replacement than the original contents", ""}) {
        if !testing.expect(t, overwrite(path, transmute([]u8)value) == nil) { return }
        actual, re := b.text(path)
        testing.expect(t, re == nil)
        testing.expect_value(t, actual, value)
    }
}
