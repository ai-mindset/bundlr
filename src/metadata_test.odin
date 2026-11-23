package bundlr

import "core:mem/virtual"
import "core:testing"
import "core:strings"

@(test)
entry_selection_and_injection :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    entries, e := application_entries("[console_scripts]\r\nblack = black:patched_main\r\nblackd = blackd:main\r\n[gui_scripts]\r\nwindow = demo.ui:Application.run [gui]\r\n", "")
    testing.expect(t, e == nil && len(entries) == 3)
    testing.expect(t, entries[2].kind == "windowed" && entries[2].attributes == "Application.run")
    selected, se := application_entries("[console_scripts]\nblack = black:main\nblackd = blackd:main\n", "black")
    testing.expect(t, se == nil && len(selected) == 1 && selected[0].module == "black")
    for v in ([]string{"a:b()", "a:b;evil", "a:__import__('os')", "a..b:c", "a:b:c", ":b", "a:"}) {
        _, ie := parse_entry(v)
        testing.expect(t, ie != nil, v)
    }
    code := launcher_python(Entry{module = "demo", attributes = "main", command = "quote\"value"})
    testing.expect(t, strings.contains(code, `"quote\"value"`))
    for example in ([]struct { name, identifier: string }{
        {"My_App", "my-app"}, {"My App", "my-app"}, {"My__ App.2", "my-app.2"},
    }) {
        testing.expect_value(t, bundle_identifier(example.name), example.identifier)
    }
}
@(test)
entry_point_whitespace_and_extras :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    for value in ([]string{"demo:main", "demo : main", " demo\t:\tmain ", "demo:main[cli]", "demo:main\t[cli]", "demo : main [ cli , other.extra ] ", "demo:main[]"}) {
        entry, err := parse_entry(value)
        testing.expect(t, err == nil && entry.module == "demo" && entry.attributes == "main", value)
    }
    for value in ([]string{"demo:main[cli", "demo:main]", "demo:main[cli]junk", "demo:main[cli][other]", "demo:main[cli,]", "demo:main[x;evil]", "demo:main()[cli]"}) {
        _, err := parse_entry(value)
        testing.expect(t, err != nil, value)
    }
}
@(test)
metadata_continuations_preserve_whitespace :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    requirements := metadata_headers("Name: example\r\nRequires-Dist: common==1; python_version >= '3.12' and\r\n sys_platform != 'unsupported'\r\nRequires-Dist: win==1; python_version >= '3.12' and\r\n\tsys_platform == 'win32'\r\n\r\nRequires-Dist: ignored\r\n", "Requires-Dist")
    testing.expect(t, len(requirements) == 2)
    testing.expect(t, requirements[0] == "common==1; python_version >= '3.12' and sys_platform != 'unsupported'")
    testing.expect(t, requirements[1] == "win==1; python_version >= '3.12' and\tsys_platform == 'win32'")
}
@(test)
wheel_portability_and_markers :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    testing.expect(t, portable_wheel("Root-Is-Purelib: true\nTag: py3-none-any\n") == nil)
    for wheel in ([]string{"Root-Is-Purelib: false\nTag: py3-none-any\n", "Root-Is-Purelib: true\n", "Root-Is-Purelib: true\nTag: py3-none-any\nTag: cp312-cp312-linux_x86_64\n"}) {
        testing.expect(t, portable_wheel(wheel) != nil)
    }
    requirements := metadata_headers("Name: example\r\nRequires-Dist: packaging==24.2\r\nRequires-Dist: colorama==0.4.6;\r\n sys_platform == 'win32'\r\n\r\nRequires-Dist: ignored\r\n", "Requires-Dist")
    testing.expect(t, len(requirements) == 2)
    testing.expect(t, requirements[1] == "colorama==0.4.6; sys_platform == 'win32'")
}
