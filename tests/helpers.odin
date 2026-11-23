#+feature dynamic-literals
package acceptance

import b "../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Error :: b.Error
Capture :: struct { stdout, stderr: [dynamic]u8 }
capture_output :: proc(build: ^b.Build, stream, value: string) {
    data := (^Capture)(build.user)
    if stream == "stdout" { append(&data.stdout, ..transmute([]u8)value) }
    else { append(&data.stderr, ..transmute([]u8)value) }
}
capture :: proc(args: []string, environment: []string = nil) -> (stdout, stderr: string, failure: Error) {
    output: Capture
    build := b.Build{output = capture_output, user = &output}
    watchdog := Watchdog{build = &build, limit = 15*time.Minute}
    worker := thread.create(watch_deadline)
    worker.data = &watchdog
    thread.start(worker)
    defer { sync.atomic_store(&watchdog.done, true); thread.join(worker); thread.destroy(worker) }
    failure = b.run(&build, args, environment)
    return string(output.stdout[:]), string(output.stderr[:]), failure
}
Watchdog :: struct { build: ^b.Build, done: bool, limit: time.Duration }
watch_deadline :: proc(t: ^thread.Thread) {
    watch := (^Watchdog)(t.data)
    started := time.tick_now()
    for !sync.atomic_load(&watch.done) {
        if b.was_signalled() || time.tick_since(started) >= watch.limit {
            sync.atomic_store(&watch.build.cancelled, true)
            return
        }
        time.sleep(10*time.Millisecond)
    }
}
command :: proc(args: []string, environment: []string = nil) -> Error {
    out, err, failure := capture(args, environment)
    if failure != nil { return fmt.aprintf("%v\n%s%s", failure, out, err) }
    return nil
}
expect :: proc(condition: bool, message: string) -> Error {
    if !condition { return message }
    return nil
}
temporary :: proc(parent := "", prefix := "bundlr-test-") -> (value: string, failure: Error) {
    result, e := os.make_directory_temp(parent, prefix, context.allocator)
    if e != nil { return "", "Cannot create owned temporary directory." }
    return b.absolute_path(result)
}
environment :: proc(overrides: map[string]string, remove: []string = nil, inherit := true) -> []string {
    inherited: []string
    if inherit { inherited, _ = os.environ(context.allocator) }
    return override_environment(inherited, overrides, remove)
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
recipient_environment :: proc(extra: map[string]string = nil) -> []string {
    values := map[string]string{"PATH" = "", "PYTHONHOME" = "bundlr-ignore-host-python", "PYTHONPATH" = "bundlr-ignore-host-packages"}
    when ODIN_OS == .Windows {
        values["SystemRoot"] = b.env("SystemRoot")
        values["PATH"] = b.join(b.env("SystemRoot"), "System32")
    }
    for key, value in extra { values[key] = value }
    return environment(values, inherit = false)
}
binary_name :: proc() -> string {
    return fmt.aprintf("bundlr-%s%s", b.host_target(), ".exe" when ODIN_OS == .Windows else "")
}
default_binary :: proc() -> string { return b.join("dist", binary_name()) }
self :: proc() -> string { path, _ := os.get_executable_path(context.allocator); return path }
read_bytes :: proc(path: string) -> (value: []u8, failure: Error) {
    data, e := os.read_entire_file(path, context.allocator)
    if e != nil { return nil, fmt.aprintf("Cannot read %s: %v", path, e) }
    return data, nil
}
// Only callers' owned temporary files may be changed through this helper.
overwrite :: proc(path: string, data: []u8) -> Error {
    file, e := os.open(path, {.Write, .Trunc})
    if e != nil { return "Cannot open owned test file." }
    defer os.close(file)
    n, we := os.write(file, data)
    if we != nil || n != len(data) { return "Cannot update owned test file." }
    return nil
}
