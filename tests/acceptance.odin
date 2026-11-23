#+feature dynamic-literals
package acceptance

import b "../src"
import "core:fmt"
import "core:os"
import "core:strings"

Git_Fixture :: struct { source: string, environment: []string }
file_uri :: proc(path: string) -> (value: string, failure: Error) {
    full := absolute(path) or_return
    full = b.replace(full, "\\", "/")
    when ODIN_OS == .Windows { full = fmt.aprintf("/%s", full) }
    hex := "0123456789ABCDEF"
    encoded: [dynamic]u8
    for byte in transmute([]u8)full {
        if byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' || byte >= '0' && byte <= '9' || strings.contains_rune("/-._~:", rune(byte)) { append(&encoded, byte) }
        else { append(&encoded, u8('%'), hex[byte>>4], hex[byte&15]) }
    }
    return fmt.aprintf("file://%s", string(encoded[:])), nil
}
git_fixture :: proc(directory: string, portable := true) -> (fixture: Git_Fixture, failure: Error) {
    if e := b.mkdir(directory); e != nil { return fixture, e }
    if e := b.write_text(b.join(directory, "application.py"), fixture_pins(GIT_APPLICATION)); e != nil { return fixture, e }
    backend := b.replace(fixture_pins(GIT_BACKEND), "PURELIB", "true" if portable else "false")
    if e := b.write_text(b.join(directory, "backend.py"), backend); e != nil { return fixture, e }
    if e := b.write_text(b.join(directory, "pyproject.toml"), "[build-system]\nrequires=[]\nbuild-backend='backend'\nbackend-path=['.']\n"); e != nil { return fixture, e }
    for args in ([][]string{
        {"git", "init", "--initial-branch=main", directory},
        {"git", "-C", directory, "add", "."},
        {"git", "-C", directory, "-c", "user.name=Bundlr acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-m", "Pinned acceptance fixture"},
    }) { if e := command(args); e != nil { return fixture, e } }
    revision, _, re := capture([]string{"git", "-C", directory, "rev-parse", "HEAD"})
    if re != nil { return fixture, re }
    uri := file_uri(directory) or_return
    source := "https://bundlr-acceptance.invalid/application.git"
    fixture.source = fmt.aprintf("%s@%s", source, b.trim(revision))
    fixture.environment = environment(map[string]string{
        "GIT_CONFIG_COUNT" = "1", "GIT_CONFIG_KEY_0" = fmt.aprintf("url.%s.insteadOf", uri), "GIT_CONFIG_VALUE_0" = source, "GIT_TERMINAL_PROMPT" = "0",
    })
    return fixture, nil
}
fixture_pins :: proc(source: string) -> string {
    return b.replace(b.replace(source, "24.2", PACKAGING_VERSION), "0.4.6", COLORAMA_VERSION)
}
packaging_acceptance :: proc(requested, evidence: string, all: bool) -> Error {
    binary := absolute(requested) or_return
    base := evidence
    keep := base != ""
    if !keep { base = temporary() or_return }
    else { if e := b.absent(base); e != nil { return e }; if e := b.mkdir(base); e != nil { return e }; base = absolute(base) or_return }
    defer { if !keep { _ = os.remove_all(base) } }
    cache := b.join(base, "tool-cache")
    python_cache := b.env("BUNDLR_PYTHON_CACHE_DIRECTORY")
    if python_cache == "" { python_cache = b.join(base, "python-cache") }
    env := environment(map[string]string{"BUNDLR_CACHE_DIRECTORY" = cache, "BUNDLR_PYTHON_CACHE_DIRECTORY" = python_cache}, []string{"BUNDLR_UV_EXECUTABLE"})
    if e := command([]string{binary, "--diagnose"}, env); e != nil { return e }
    fixture := git_fixture(b.join(base, "portable")) or_return
    git_env := fixture.environment
    append_env := override_environment(git_env, map[string]string{"BUNDLR_CACHE_DIRECTORY" = cache, "BUNDLR_PYTHON_CACHE_DIRECTORY" = python_cache}, []string{"BUNDLR_UV_EXECUTABLE"})
    targets := []string{b.host_target()}
    values := b.TARGETS
    if all { targets = values[:] }
    native_runtime := ""
    for target in targets {
        for name, i in ([2]string{"Black", "GitDemo"}) {
            source, entry, build_env := fmt.aprintf("black==%s", BLACK_VERSION), "black", env
            if i == 1 { source, entry, build_env = fixture.source, "git-demo", append_env }
            output := b.join(base, "applications")
            fmt.printf("Packaging acceptance: %s for %s\n", name, target)
            args := []string{binary, "--name", name, "--command", entry, "--target", target, "--output", output, source}
            if e := command(args, build_env); e != nil { return e }
            extension := ".zip" if target == "windows-x86_64" else ".tar.gz"
            archive := b.join(output, fmt.aprintf("%s-%s%s", name, target, extension))
            selected_source := fixture.source if i == 1 else ""
            artifact := verify_recipient(archive, b.join(base, fmt.aprintf("extracted-%s-%s", name, target)), name, target, selected_source, target == b.host_target()) or_return
            if i == 0 && target == b.host_target() { native_runtime = b.join(resources(artifact, target), "runtime") }
            checksum := b.file_hash(archive) or_return
            _, _, collision := capture(args, build_env)
            if collision == nil || !b.matches_hash(archive, checksum) { return "Packaging collision replaced a completed archive." }
            dirs, de := os.read_directory_by_path(output, -1, context.allocator)
            if de != nil { return "Cannot inspect packaging stage cleanup." }
            for dir in dirs { if strings.has_prefix(dir.name, ".bundlr-") { return "Packaging left a staging directory behind." } }
        }
    }
    rejected := git_fixture(b.join(base, "nonportable"), false) or_return
    rejected_env := override_environment(rejected.environment, map[string]string{"BUNDLR_CACHE_DIRECTORY" = cache, "BUNDLR_PYTHON_CACHE_DIRECTORY" = python_cache}, []string{"BUNDLR_UV_EXECUTABLE"})
    rejected_output := b.join(base, "rejected")
    _, rejection_text, rejection := capture([]string{binary, "--name", "Rejected", "--command", "git-demo", "--output", rejected_output, rejected.source}, rejected_env)
    if rejection == nil || !strings.contains(rejection_text, "pure") && !strings.contains(rejection_text, "portable") { return "Nonportable Git root was not rejected." }
    files := b.files_in(rejected_output) or_return
    if len(files) != 0 { return "Rejected Git root left an artifact." }
    ambiguous_output := b.join(base, "ambiguous")
    _, ambiguity_text, ambiguity := capture([]string{binary, "--output", ambiguous_output, fmt.aprintf("black==%s", BLACK_VERSION)}, env)
    if ambiguity == nil || !strings.contains(ambiguity_text, "--command") { return "Ambiguous application command was silently selected." }
    ambiguous_files := b.files_in(ambiguous_output) or_return
    if len(ambiguous_files) != 0 { return "Ambiguous command left an artifact." }
    if native_runtime == "" { return "Native recipient runtime was not exercised." }
    if e := managed_checks(native_runtime); e != nil { return e }
    when ODIN_OS == .Windows {
        output := b.join(base, "windowed")
        if e := command([]string{binary, "--name", "GitWindow", "--command", "git-window", "--kind", "windowed", "--output", output, fixture.source}, append_env); e != nil { return e }
        artifact := verify_recipient(b.join(output, "GitWindow-windows-x86_64.zip"), b.join(base, "extracted-gui"), "GitWindow", "windows-x86_64", fixture.source, false) or_return
        marker := b.join(base, "gui-success.txt")
        if e := command([]string{launcher(artifact, "GitWindow", "windows-x86_64")}, recipient_environment(map[string]string{"BUNDLR_GUI_MARKER" = marker})); e != nil { return e }
        if (b.text(marker) or_return) != "tkinter event loop passed" { return "Windowed pythonw/Tk recipient did not complete." }
    }
    fmt.println("Production builder, managed resolver and native recipient acceptance passed:", b.host_target())
    return nil
}
override_environment :: proc(values: []string, overrides: map[string]string, remove: []string = nil) -> []string {
    result: [dynamic]string
    for value in values {
        eq := strings.index(value, "=")
        if eq > 0 {
            key := strings.to_upper(value[:eq])
            skip := false
            for replacement in overrides { if strings.to_upper(replacement) == key { skip = true } }
            for removed in remove { if strings.to_upper(removed) == key { skip = true } }
            if skip { continue }
        }
        append(&result, value)
    }
    for key, value in overrides { append(&result, fmt.aprintf("%s=%s", key, value)) }
    return result[:]
}
