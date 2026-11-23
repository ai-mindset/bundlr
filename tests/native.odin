#+feature dynamic-literals
package acceptance

import b "../src"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Native_Case :: struct { name: string, run: proc(root, binary: string) -> Error }
native_check :: proc(binary: string) -> Error {
    cases := []Native_Case{
        {"literal subprocess arguments and failures", check_process},
        {"simultaneous stdout and stderr", check_streams},
        {"cancellation and descendant termination", check_cancel},
        {"independent ZIP decoding, modes and CRCs", check_zip},
        {"classic ZIP size guards", check_zip_limit},
        {"atomic publication and collision preservation", check_publication},
        {"concurrent publication winners", check_publication_race},
        {"pre-download collisions", check_collision},
        {"verified runtime extraction", check_runtime},
        {"HTTPS protocol restrictions", check_https},
        {"four-target layouts, evidence and launcher ZIPs", check_layouts},
        {"entry point ambiguity and explicit selection", check_entry},
        {"build output and sidecar collisions", check_build_collisions},
    }
    for test in cases {
        root := temporary() or_return
        failure := test.run(root, binary)
        _ = os.remove_all(root)
        if failure != nil { return fmt.aprintf("Native test failed (%s): %v", test.name, failure) }
        fmt.printf("Passed: %s\n", test.name)
    }
    when ODIN_OS != .Windows { if e := check_saturated_console(); e != nil { return e } }
    return nil
}
check_process :: proc(root, binary: string) -> Error {
    args := []string{"", "literal spaces; $(safe)", `quoted "value"`, "tab\tvalue", "\\backslash", "space and slash\\", "é漢字", ""}
    command: [dynamic]string
    append(&command, self(), "--fixture", "arguments")
    append(&command, ..args)
    out, stderr, e := capture(command[:])
    if e != nil || stderr != "" { return "Cannot capture literal arguments." }
    parsed: []string
    if json.unmarshal(transmute([]u8)out, &parsed) != nil || len(parsed) != len(args) { return "Argument count changed." }
    for value, i in args { if value != parsed[i] { return "Subprocess arguments changed." } }
    _, _, failed := capture([]string{self(), "--fixture", "fail"})
    if failed == nil || !strings.contains(fmt.aprintf("%v", failed), "37") { return "Subprocess exit status was lost." }
    _, _, missing := capture([]string{b.join(root, "missing executable")})
    return expect(missing != nil, "Missing subprocess was accepted.")
}
check_streams :: proc(root, binary: string) -> Error {
    out, stderr, e := capture([]string{self(), "--fixture", "streams"})
    if e != nil || len(out) != 1048576 || len(stderr) != 1048576 { return "Concurrent output was lost or blocked." }
    for byte in out { if byte != 'o' { return "Corrupt stdout." } }
    for byte in stderr { if byte != 'e' { return "Corrupt stderr." } }
    return nil
}
Cancel_Trigger :: struct { build: ^b.Build, marker: string }
cancel_after_marker :: proc(thread: ^thread.Thread) {
    trigger := (^Cancel_Trigger)(thread.data)
    started := time.tick_now()
    for time.tick_since(started) < 5*time.Second {
        if os.exists(trigger.marker) { time.sleep(50*time.Millisecond); break }
        time.sleep(10*time.Millisecond)
    }
    sync.atomic_store(&trigger.build.cancelled, true)
}
check_cancel :: proc(root, binary: string) -> Error {
    marker := b.join(root, "descendants.json")
    data: Capture
    build := b.Build{output = capture_output, user = &data}
    trigger := Cancel_Trigger{&build, marker}
    worker := thread.create(cancel_after_marker)
    worker.data = &trigger
    thread.start(worker)
    started := time.tick_now()
    e := b.run(&build, []string{self(), "--fixture", "descendants", marker})
    thread.join(worker)
    thread.destroy(worker)
    if e == nil || !build.cancelled || time.tick_since(started) > 8*time.Second || !strings.contains(string(data.stdout[:]), "ready") { return "Cancellation did not stop a streaming subprocess promptly." }
    return descendants_stopped(marker)
}
check_zip :: proc(root, binary: string) -> Error {
    source := b.join(root, "source")
    if e := b.mkdir(b.join(source, "sub")); e != nil { return e }
    if e := b.write_text(b.join(source, "empty"), ""); e != nil { return e }
    if e := b.write_text(b.join(source, "launch"), "#!/bin/sh\nexit 0\n", os.perm_number(0o755)); e != nil { return e }
    data := make([]u8, 76800)
    for &byte, i in data { byte = u8(i%256) }
    if e := b.write_bytes(b.join(source, "sub", "unicodé.txt"), data); e != nil { return e }
    when ODIN_OS != .Windows { if os.symlink(root, b.join(source, "outside-link")) != nil { return "Cannot prepare ZIP symlink fixture." } }
    archive := b.join(root, "client.zip")
    if e := b.create_zip(nil, source, archive, "fixture"); e != nil { return e }
    bytes := read_bytes(archive) or_return
    entries := read_zip(bytes) or_return
    if len(entries) != 3 { return "ZIP traversal included a symlink or lost a file." }
    found := false
    for entry in entries {
        if entry.name == "fixture/sub/unicodé.txt" { found = b.bytes_hash(entry.data) == b.bytes_hash(data) }
        when ODIN_OS != .Windows { if entry.name == "fixture/launch" && entry.mode&0o777 != 0o755 { return "ZIP executable mode changed." } }
    }
    if !found { return "ZIP UTF-8 member or contents changed." }
    if b.create_zip(nil, source, archive, "fixture") == nil { return "ZIP writer overwrote an archive." }
    if b.bytes_hash(bytes) != (b.file_hash(archive) or_return) { return "ZIP collision changed archive bytes." }
    payload := strings.index(string(bytes), "#!/bin/sh\nexit 0\n")
    if payload < 0 { return "Cannot locate ZIP corruption fixture." }
    bytes[payload] = bytes[payload]~1
    _, corrupt := read_zip(bytes)
    return expect(corrupt != nil, "ZIP corruption was not detected.")
}
check_zip_limit :: proc(root, binary: string) -> Error {
    source := b.join(root, "large")
    if e := b.mkdir(source); e != nil { return e }
    file, e := os.open(b.join(source, "sparse"), {.Write, .Create, .Excl, .Sparse})
    if e != nil { return "Cannot create sparse ZIP size fixture." }
    defer os.close(file)
    if os.truncate(file, 0x1_0000_0000) != nil { return "Cannot extend sparse ZIP size fixture." }
    rejected := b.create_zip(nil, source, b.join(root, "large.zip"), "fixture")
    return expect(rejected != nil && strings.contains(fmt.aprintf("%v", rejected), "ZIP size limit"), "Classic ZIP size guard failed.")
}
check_publication :: proc(root, binary: string) -> Error {
    source, destination := b.join(root, "stage"), b.join(root, "published")
    if e := b.mkdir(source); e != nil { return e }
    if e := b.write_text(b.join(source, "payload"), "new"); e != nil { return e }
    if e := b.mkdir(destination); e != nil { return e }
    if b.publish_directory(source, destination) == nil { return "Publication replaced an existing empty directory." }
    if os.remove(destination) != nil { return "Cannot remove owned publication fixture." }
    if e := b.write_text(destination, "existing"); e != nil { return e }
    if b.publish_directory(source, destination) == nil || (b.text(destination) or_return) != "existing" { return "Publication replaced an existing file." }
    if os.remove(destination) != nil { return "Cannot remove owned publication fixture." }
    if e := b.publish_directory(source, destination); e != nil { return e }
    return expect(!os.exists(source) && (b.text(b.join(destination, "payload")) or_return) == "new", "Publication lost staged data.")
}
Publish_Job :: struct { source, destination: string, error: Error }
check_publication_race :: proc(root, binary: string) -> Error {
    jobs: [2]Publish_Job
    threads: [2]^thread.Thread
    for &job, i in jobs {
        job.source, job.destination = b.join(root, fmt.aprintf("source-%d", i)), b.join(root, "winner")
        if e := b.mkdir(job.source); e != nil { return e }
        if e := b.write_text(b.join(job.source, "identity"), fmt.aprintf("%d", i)); e != nil { return e }
        threads[i] = thread.create(proc(t: ^thread.Thread) {
            job := (^Publish_Job)(t.data)
            job.error = b.publish_directory(job.source, job.destination)
        })
        threads[i].data = &jobs[i]
    }
    for t in threads { thread.start(t) }
    for t in threads { thread.join(t); thread.destroy(t) }
    successes := 0
    for job, i in jobs {
        if job.error == nil {
            successes += 1
            if (b.text(b.join(job.destination, "identity")) or_return) != fmt.aprintf("%d", i) { return "Concurrent publication winner changed." }
        }
    }
    return expect(successes == 1, "Concurrent publication must have exactly one winner.")
}
check_collision :: proc(root, binary: string) -> Error {
    output := b.join(root, "artifacts")
    if e := b.mkdir(output); e != nil { return e }
    checksum := b.join(output, "Demo-linux-x86_64.tar.gz.sha256")
    if e := b.write_text(checksum, "do not replace"); e != nil { return e }
    request := b.Request{"demo==1", "Demo", "console", "demo", "3.12", []string{"linux-x86_64"}, output}
    _, e := b.package_targets(nil, request)
    if e == nil || (b.text(checksum) or_return) != "do not replace" { return "Pre-download collision did not preserve output." }
    files := b.files_in(output) or_return
    return expect(len(files) == 1, "Collision wrote additional output.")
}
check_runtime :: proc(root, binary: string) -> Error {
    source := b.join(root, "source", "python", "bin")
    if e := b.mkdir(source); e != nil { return e }
    if e := b.write_text(b.join(source, "python3"), "fixture-runtime", os.perm_number(0o755)); e != nil { return e }
    archive := b.join(root, "python.tar.gz")
    if e := command([]string{"tar", "-C", b.join(root, "source"), "-czf", archive, "python"}); e != nil { return e }
    sha := b.file_hash(archive) or_return
    destination := b.join(root, "runtime")
    if e := b.extract_verified_runtime(nil, archive, sha, destination, "bin/python3"); e != nil { return e }
    if (b.text(b.join(destination, "bin", "python3")) or_return) != "fixture-runtime" { return "Runtime extraction changed bytes." }
    corrupt := "corrupt archive"
    if e := overwrite(archive, transmute([]u8)corrupt); e != nil { return e }
    rejected := b.join(root, "rejected")
    e := b.extract_verified_runtime(nil, archive, sha, rejected, "bin/python3")
    return expect(e != nil && !os.exists(rejected), "Runtime hash failure wrote output.")
}
check_https :: proc(root, binary: string) -> Error {
    file := b.join(root, "local-data")
    if e := b.write_text(file, "fixture bytes"); e != nil { return e }
    e := b.download(nil, fmt.aprintf("file://%s", file), b.join(root, "download"))
    return expect(e != nil && (b.text(b.join(root, "download")) or_return) == "", "HTTPS download accepted a local-file URL.")
}
layout :: proc(root, target: string, name := "Demo App") -> Error {
    if e := b.mkdir(b.join(root, "runtime")); e != nil { return e }
    metadata := b.join(root, "packages", "demo-1.dist-info")
    if e := b.mkdir(b.join(metadata, "licenses")); e != nil { return e }
    if e := b.write_text(b.join(metadata, "METADATA"), "Name: demo\nVersion: 1\n"); e != nil { return e }
    if e := b.write_text(b.join(metadata, "entry_points.txt"), "[console_scripts]\ndemo = demo:main\nother = demo:main\n"); e != nil { return e }
    if e := b.write_text(b.join(metadata, "licenses", "LICENSE.txt"), "Fixture MIT licence"); e != nil { return e }
    if e := b.write_text(b.join(root, "runtime", "LICENSE.txt"), "Fixture Python licence"); e != nil { return e }
    if target == "windows-x86_64" {
        dir := b.join(root, "runtime", "Lib", "site-packages", "pip", "_vendor", "distlib")
        if e := b.mkdir(dir); e != nil { return e }
        stub := make([]u8, 128)
        stub[0], stub[1] = 'M', 'Z'
        if e := b.write_bytes(b.join(dir, "t64.exe"), stub); e != nil { return e }
    }
    request := b.Request{"demo==1", name, "console", "demo", "3.12", []string{target}, root}
    entry := b.Entry{command = "demo", kind = "console", module = "demo", attributes = "main"}
    if e := b.validate(request); e != nil { return e }
    if e := b.create_launcher(request, target, root, entry); e != nil { return e }
    return b.write_evidence(nil, request, target, root, b.join(root, "packages"))
}
check_layouts :: proc(root, binary: string) -> Error {
    for target in b.TARGETS {
        directory := b.join(root, target)
        if strings.has_prefix(target, "macos-") { directory = b.join(directory, "Contents", "Resources") }
        if e := layout(directory, target); e != nil { return e }
        manifest: b.Manifest
        data := read_bytes(b.join(directory, "bundlr-manifest.json")) or_return
        if json.unmarshal(data, &manifest) != nil || manifest.target != target || manifest.command != "demo" { return "Layout manifest changed." }
        if e := verify_inventory(directory); e != nil { return e }
        licences := b.text(b.join(directory, "THIRD_PARTY_LICENSES.txt")) or_return
        if !strings.contains(licences, "Fixture MIT licence") { return "Dependency licence was omitted." }
        if target == "windows-x86_64" {
            bytes := read_bytes(b.join(directory, "Demo App.exe")) or_return
            entries := read_zip(bytes) or_return
            if len(entries) != 1 || entries[0].name != "__main__.py" || !strings.contains(string(entries[0].data), "sys.path.insert(0, _packages)") { return "Windows appended launcher ZIP changed." }
        }
    }
    for name in ([]string{"My_App", "My App", "My__ App.2"}) {
        directory := b.join(root, name, "Contents", "Resources")
        if e := layout(directory, "macos-arm64", name); e != nil { return e }
        plist := b.text(b.join(directory, "..", "Info.plist")) or_return
        if !strings.contains(plist, fmt.aprintf("dev.bundlr.%s", b.bundle_identifier(name))) || strings.contains(b.bundle_identifier(name), "_") { return "macOS bundle identifier contains unsupported characters." }
    }
    return nil
}
check_entry :: proc(root, binary: string) -> Error {
    if e := layout(root, b.host_target()); e != nil { return e }
    packages := b.join(root, "packages")
    _, ambiguous := b.find_entry(packages, "")
    entry, e := b.find_entry(packages, "demo")
    _, absent := b.find_entry(packages, "absent")
    return expect(ambiguous != nil && e == nil && entry.command == "demo" && absent != nil, "Entry point selection contract changed.")
}
check_build_collisions :: proc(root, binary: string) -> Error {
    for suffix, i in ([]string{"", ".json", ".sha256"}) {
        output := b.join(root, fmt.aprintf("occupied-%d", i))
        path := fmt.aprintf("%s%s", output, suffix)
        if e := b.write_text(path, "existing output"); e != nil { return e }
        env := environment(map[string]string{"ODIN" = b.join(root, "missing compiler")})
        _, message, e := capture([]string{self(), "build", output}, env)
        if e == nil || !strings.contains(message, "Refusing to overwrite") || (b.text(path) or_return) != "existing output" { return "Build collision did not precede compiler discovery." }
    }
    when ODIN_OS != .Windows {
        for suffix, i in ([]string{"", ".json", ".sha256"}) {
            output := b.join(root, fmt.aprintf("symlink-%d", i))
            target := b.join(root, fmt.aprintf("missing-target-%d", i))
            path := fmt.aprintf("%s%s", output, suffix)
            if os.symlink(target, path) != nil { return "Cannot create dangling build collision fixture." }
            _, message, e := capture([]string{self(), "build", output})
            if e == nil || !strings.contains(message, "Refusing to overwrite") || os.exists(target) { return "Build followed a dangling output symlink." }
        }
    }
    return nil
}
