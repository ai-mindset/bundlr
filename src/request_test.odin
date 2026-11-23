package bundlr

import "core:mem/virtual"
import "core:testing"

@(test)
source_validation :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    for input in ([]string{"black==26.5.1", "demo[cli,fast]==1!2.0rc1.post2.dev3+local.1", "x==v1.0", "a==1RC1", "https://[::1]/app.git", "git+https://example.org/app.git@abc", " https://example.org/app.git "}) {
        _, e := parse_source(input)
        testing.expect(t, e == nil, input)
    }
    for input in ([]string{"", "black", "black>=1", "a==*", "a==1;evil", "a==1\n", "a==1==2", "a[bad!]==1", "http://example.org/a", "git+ssh://example.org/a", "https:///a", "https://bad host/a", "https://host:bad/a", "https://user:password@example.org/a"}) {
        _, e := parse_source(input)
        // Source trimming is deliberate, as in the original CLI/browser.
        if input == "a==1\n" { testing.expect(t, e == nil) } else { testing.expect(t, e != nil, input) }
    }
}
@(test)
request_contract :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    r, e := parse_cli([]string{"--name", "Black", "--command", "black", "--target", "all", "black==26.5.1"})
    testing.expect(t, e == nil)
    testing.expect(t, len(r.targets) == 4 && r.command == "black")
    for args in ([][]string{
        {"--target", "all", "--target", "linux-x86_64", "a==1"},
        {"--name", "../escape", "a==1"}, {"--python", "3.13", "a==1"},
        {"--kind", "hidden", "a==1"}, {"--name", "NUL", "a==1"},
        {"a==1", "extra"}, {"--target", "invalid", "a==1"}, {"--name"},
        {"--output", "bad\x00path", "a==1"},
    }) { _, failure := parse_cli(args); testing.expect(t, failure != nil) }
    git, ge := parse_cli([]string{"https://example.org/team/App.git@1234"})
    testing.expect(t, ge == nil && git.applicationName == "App")
    testing.expect(t, distribution("windows-x86_64").executable == "python.exe")
    testing.expect(t, distribution("macos-arm64").triple == "aarch64-apple-darwin")
}
