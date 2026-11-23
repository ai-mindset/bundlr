package bundlr

import "core:mem/virtual"
import "core:testing"

@(test)
windows_arguments_preserve_empty_whitespace_quotes_and_slashes :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    examples := []struct { args: []string, line: string }{
        {[]string{"python.exe", "before", "", "after"}, `"python.exe" "before" "" "after"`},
        {[]string{"C:\\Program Files\\Python\\python.exe", "tab\tvalue", "\t"}, "\"C:\\Program Files\\Python\\python.exe\" \"tab\tvalue\" \"\t\""},
        {[]string{"python.exe", `a\b`, `space and slash\`, `quoted "value"`, `\"`, ""}, `"python.exe" "a\b" "space and slash\\" "quoted \"value\"" "\\\"" ""`},
        {[]string{"python.exe", "é漢字", "literal spaces; $(safe)"}, `"python.exe" "é漢字" "literal spaces; $(safe)"`},
    }
    for example in examples {
        line := windows_command_line(example.args)
        testing.expect_value(t, line, example.line)
    }
}
