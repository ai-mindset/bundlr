package main

import b "../src"
import t "../tests"
import "core:fmt"
import "core:os"

check :: proc() -> Error {
    odin := compiler() or_return
    if _, _, e := prepared_uv(); e != nil { return e }
    if e := b.mkdir(".build"); e != nil { return e }
    stage := t.temporary(".build", "bundlr-check-") or_return
    defer os.remove_all(stage)
    if e := t.command([]string{odin, "check", "src", "-vet", "-strict-style"}); e != nil { return e }
    for optimization in ([]string{"none", "speed"}) {
        output := b.join(stage, "unit-tests.exe" when ODIN_OS == .Windows else "unit-tests")
        for suite in ([]string{"src", "tests", "scripts"}) {
            args := make([dynamic]string)
            append(&args, odin, "test", suite, fmt.aprintf("-o:%s", optimization), "-vet", "-strict-style", fmt.aprintf("-out:%s", output))
            if suite != "src" { append(&args, "-define:BUNDLR_EMBED_UV=false") }
            if e := t.command(args[:]); e != nil { return e }
        }
        fmt.printf("Passed: Odin source, harness and driver units (%s)\n", optimization)
    }
    binary := b.join(stage, t.binary_name())
    if e := build(binary); e != nil { return e }
    if e := t.native_check(); e != nil { return e }
    if e := t.verify(binary); e != nil { return e }
    fmt.println("Odin source, native integration and compiled integrity checks passed.")
    return nil
}
