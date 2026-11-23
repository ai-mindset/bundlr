package main

import b "../src"
import t "../tests"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

check :: proc() -> Error {
    odin := compiler() or_return
    if _, _, e := prepared_uv(); e != nil { return e }
    if e := b.mkdir(".build"); e != nil { return e }
    stage := t.temporary(".build", "bundlr-check-") or_return
    defer os.remove_all(stage)
    if e := t.command([]string{odin, "check", "src", "-vet", "-strict-style"}); e != nil { return e }
    for optimization in ([]string{"none", "speed"}) {
        output := b.join(stage, "unit-tests.exe" when ODIN_OS == .Windows else "unit-tests")
        if e := t.command([]string{odin, "test", "src", fmt.aprintf("-o:%s", optimization), "-vet", "-strict-style", fmt.aprintf("-out:%s", output)}); e != nil { return e }
        if e := t.command([]string{odin, "test", "tests", "-define:BUNDLR_EMBED_UV=false", fmt.aprintf("-o:%s", optimization), "-vet", "-strict-style", fmt.aprintf("-out:%s", output)}); e != nil { return e }
        fmt.printf("Passed: Odin source and harness units (%s)\n", optimization)
    }
    if e := check_bootstrap(odin, stage); e != nil { return e }
    binary := b.join(stage, t.binary_name())
    if e := build(binary); e != nil { return e }
    if e := t.native_check(binary); e != nil { return e }
    if e := t.verify(binary); e != nil { return e }
    fmt.println("Odin source, native integration and compiled integrity checks passed.")
    return nil
}
check_bootstrap :: proc(odin, stage: string) -> Error {
    root := b.join(stage, "clean-checkout")
    for directory in ([]string{"src", "scripts", "tests"}) {
        files := b.files_in(directory) or_return
        for file in files {
            if !strings.has_suffix(file, ".odin") && file != "desktop.html" { continue }
            path := b.join(root, directory, file)
            if e := b.mkdir(filepath.dir(path)); e != nil { return e }
            bytes := t.read_bytes(b.join(directory, file)) or_return
            if e := b.write_bytes(path, bytes); e != nil { return e }
        }
    }
    output := b.join(root, "bootstrap.exe" when ODIN_OS == .Windows else "bootstrap")
    if e := t.command([]string{t.self(), "--fixture", "cwd", root, odin, "build", "scripts", "-define:BUNDLR_EMBED_UV=false", "-vet", "-strict-style", fmt.aprintf("-out:%s", output)}); e != nil { return e }
    fmt.println("Passed: native developer-tool bootstrap without prepared payloads or scripting toolchains")
    return nil
}
