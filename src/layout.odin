package bundlr

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Manifest :: struct {
    formatVersion: int,
    applicationName, applicationKind, command, source, target, pythonVersion, bundlrVersion: string,
}
Dependency :: struct { name, version: string }
Inventory :: struct { formatVersion: int, dependencies: []Dependency }
launcher_python :: proc(e: Entry) -> string {
    return fmt.aprintf("import sys\nimport site\nimport os\n_packages = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), 'packages')\nsys.path.insert(0, _packages)\nsite.addsitedir(_packages)\nsys.argv[0] = os.path.join(os.path.dirname(sys.argv[0]), %s)\nimport %s as _bundlr_module\nraise SystemExit(_bundlr_module.%s())\n", json_text(e.command), e.module, e.attributes)
}
bundle_identifier :: proc(name: string) -> string {
    identifier: [dynamic]u8
    replacing := false
    for c in strings.to_lower(name) {
        if 'a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '.' || c == '-' {
            append(&identifier, u8(c))
            replacing = false
        } else if !replacing {
            append(&identifier, '-')
            replacing = true
        }
    }
    return string(identifier[:])
}
create_launcher :: proc(r: Request, target, root: string, e: Entry) -> Error {
    code := launcher_python(e)
    if target == "windows-x86_64" {
        stub_name := "t64.exe"
        py := "python.exe"
        if r.applicationKind == "windowed" { stub_name = "w64.exe"; py = "pythonw.exe" }
        stub, re := os.read_entire_file(join(root, "runtime", "Lib", "site-packages", "pip", "_vendor", "distlib", stub_name), os.heap_allocator())
        if re != nil { return "Python runtime does not contain the Windows launcher stub." }
        defer delete(stub, os.heap_allocator())
        f, oe := os.open(join(root, fmt.aprintf("%s.exe", r.applicationName)), {.Write, .Create, .Excl})
        if oe != nil { return "Cannot create Windows launcher." }
        defer os.close(f)
        z := Zip{file = f}
        if err := zip_write(&z, stub); err != nil { return err }
        if err := zip_write(&z, transmute([]u8)fmt.aprintf("#!<launcher_dir>\\runtime\\%s -I -B\n", py)); err != nil { return err }
        // ZIP offsets are relative to the appended ZIP, as distlib expects.
        z.offset = 0
        if err := zip_add(&z, "__main__.py", transmute([]u8)code); err != nil { return err }
        return zip_finish(&z)
    }
    if err := write_text(join(root, "bundlr_launcher.py"), code); err != nil { return err }
    executable := join(root, r.applicationName)
    relative := ""
    if strings.has_prefix(target, "macos-") {
        macos := join(root, "..", "MacOS")
        if err := mkdir(macos); err != nil { return err }
        executable = join(macos, r.applicationName)
        relative = "/../Resources"
        plist := fmt.aprintf(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>%s</string><key>CFBundleIdentifier</key><string>dev.bundlr.%s</string><key>CFBundleName</key><string>%s</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
`, r.applicationName, bundle_identifier(r.applicationName), r.applicationName)
        if err := write_text(join(root, "..", "Info.plist"), plist); err != nil { return err }
    }
    prefix :: "#!/bin/sh\ncase \"$0\" in */*) ROOT=${0%/*};; *) ROOT=.;; esac\n"
    locate := fmt.aprintf("ROOT=$(CDPATH= cd -- \"$ROOT%s\" && pwd) || exit 1\n", relative)
    suffix :: "exec \"$ROOT/runtime/bin/python3\" -I -B \"$ROOT/bundlr_launcher.py\" \"$@\"\n"
    return write_text(executable, strings.join([]string{prefix, locate, suffix}, ""), os.perm_number(0o755))
}
write_evidence :: proc(b: ^Build, r: Request, target, root, packages: string) -> Error {
    manifest := Manifest{1, r.applicationName, r.applicationKind, r.command, r.source, target, PYTHON_VERSION, VERSION}
    if err := write_text(join(root, "bundlr-manifest.json"), fmt.aprintf("%s\n", json_text(manifest))); err != nil { return err }
    dirs, de := os.read_directory_by_path(packages, -1, context.allocator)
    if de != nil { return "Cannot inventory dependencies." }
    dependencies: [dynamic]Dependency
    licences: [dynamic]string
    runtime_licence, le := text(join(root, "runtime", "LICENSE.txt"))
    if le == nil { append(&licences, fmt.aprintf("===== Python runtime/LICENSE.txt =====\n%s", runtime_licence)) }
    for dir in dirs {
        if dir.type != .Directory || !strings.has_suffix(dir.name, ".dist-info") { continue }
        metadata := text(join(packages, dir.name, "METADATA")) or_return
        append(&dependencies, Dependency{metadata_header(metadata, "Name"), metadata_header(metadata, "Version")})
        files := files_in(join(packages, dir.name)) or_return
        slice.sort(files)
        for file in files {
            name := strings.to_upper(filepath.base(file))
            if !strings.has_prefix(name, "LICENSE") && !strings.has_prefix(name, "LICENCE") && !strings.has_prefix(name, "NOTICE") && !strings.has_prefix(name, "COPYING") { continue }
            licence := text(join(packages, dir.name, file)) or_return
            append(&licences, fmt.aprintf("===== %s/%s =====\n%s", dir.name, file, licence))
        }
    }
    slice.sort_by(dependencies[:], proc(a, b: Dependency) -> bool { return a.name < b.name })
    if err := write_text(join(root, "bundlr-dependencies.json"), fmt.aprintf("%s\n", json_text(Inventory{1, dependencies[:]}))); err != nil { return err }
    if err := write_text(join(root, "THIRD_PARTY_LICENSES.txt"), fmt.aprintf("%s\n", strings.join(licences[:], "\n\n"))); err != nil { return err }
    files := files_in(root) or_return
    lines: [dynamic]string
    for file in files {
        if err := check_cancel(b); err != nil { return err }
        digest := file_hash(join(root, file)) or_return
        append(&lines, fmt.aprintf("%s  %s", digest, replace(file, "\\", "/")))
    }
    slice.sort(lines[:])
    return write_text(join(root, "SHA256SUMS"), fmt.aprintf("%s\n", strings.join(lines[:], "\n")))
}
