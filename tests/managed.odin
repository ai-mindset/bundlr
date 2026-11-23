#+feature dynamic-literals
package acceptance

import b "../src"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Saved_Env :: struct { key, value: string, exists: bool }
managed_acceptance :: proc() -> Error {
    root := temporary() or_return
    defer os.remove_all(root)
    runtime := b.join(root, "runtime")
    if e := b.materialize_python(nil, b.host_target(), runtime); e != nil { return e }
    return managed_checks(runtime)
}
set_environment :: proc(values: map[string]string) -> (saved: []Saved_Env, failure: Error) {
    result: [dynamic]Saved_Env
    for key, value in values {
        previous, exists := os.lookup_env(key, context.allocator)
        append(&result, Saved_Env{key, previous, exists})
        if os.set_env(key, value) != nil { restore_environment(result[:]); return nil, "Cannot configure managed-runtime test environment." }
    }
    return result[:], nil
}
restore_environment :: proc(saved: []Saved_Env) {
    for entry in saved { if entry.exists { _ = os.set_env(entry.key, entry.value) } else { _ = os.unset_env(entry.key) } }
}
wheel :: proc(root, name: string, requirements: []string = nil, version := "1.0", tag := "py3-none-any", python := ">=3.12", code := "def main(): return 0\n") -> (path: string, failure: Error) {
    normalized := b.replace(name, "-", "_")
    metadata := fmt.aprintf("%s-%s.dist-info/", normalized, version)
    path = b.join(root, fmt.aprintf("%s-%s-%s.whl", normalized, version, tag))
    file, e := os.open(path, {.Write, .Create, .Excl})
    if e != nil { return "", "Cannot create local wheel fixture." }
    defer os.close(file)
    archive := b.Zip{file = file}
    headers := fmt.aprintf("Metadata-Version: 2.3\nName: %s\nVersion: %s\nRequires-Python: %s\n", name, version, python)
    for requirement in requirements { headers = fmt.aprintf("%sRequires-Dist: %s\n", headers, requirement) }
    pure := "true" if strings.has_suffix(tag, "-none-any") else "false"
    files := map[string]string{
        fmt.aprintf("%s.py", normalized) = code,
        fmt.aprintf("%sMETADATA", metadata) = fmt.aprintf("%s\n", headers),
        fmt.aprintf("%sWHEEL", metadata) = fmt.aprintf("Wheel-Version: 1.0\nRoot-Is-Purelib: %s\nTag: %s\n", pure, tag),
        fmt.aprintf("%sentry_points.txt", metadata) = fmt.aprintf("[console_scripts]\nfixture-cli = %s:main\n", normalized),
        fmt.aprintf("%sRECORD", metadata) = "",
    }
    for member, contents in files { if e := b.zip_add(&archive, member, transmute([]u8)contents); e != nil { return "", e } }
    return path, b.zip_finish(&archive)
}
root_dependencies :: proc(target, packages: string) -> Error {
    entry := b.find_entry(packages, "fixture-cli") or_return
    build := b.Build{}
    return b.install_git_dependencies(&build, target, packages, entry)
}
managed_checks :: proc(runtime: string) -> Error {
    root := temporary() or_return
    defer os.remove_all(root)
    python := b.join(runtime, b.distribution(b.host_target()).executable)
    venv := b.join(root, "managed-venv")
    if e := command([]string{python, "-I", "-m", "venv", "--without-pip", venv}); e != nil { return e }
    saved := set_environment(map[string]string{
        "VIRTUAL_ENV" = venv, "UV_OFFLINE" = "1", "UV_NO_INDEX" = "1", "UV_FIND_LINKS" = root,
        "UV_CACHE_DIR" = b.join(root, "uv-cache"), "UV_PYTHON_INSTALL_DIR" = b.join(root, "managed-python"),
        "BUNDLR_CACHE_DIRECTORY" = b.join(root, "tool-cache"),
    }) or_return
    defer restore_environment(saved)
    build := b.Build{}
    for name in ([]string{"bundlr-common", "bundlr-win"}) { if _, e := wheel(root, name); e != nil { return e } }
    if _, e := wheel(root, "bundlr-fixture", []string{"bundlr-common==1.0", `bundlr-win==1.0; sys_platform == "win32"`}); e != nil { return e }
    for target in b.TARGETS {
        packages := b.join(root, fmt.aprintf("markers-%s", target))
        if e := b.binary_install(&build, target, packages, []string{"bundlr-fixture==1.0"}); e != nil { return e }
        if !os.exists(b.join(packages, "bundlr_common.py")) || os.exists(b.join(packages, "bundlr_win.py")) != (target == "windows-x86_64") { return "Target environment markers changed." }
    }
    if _, e := wheel(root, "bundlr-native", tag = "cp312-cp312-linux_x86_64"); e != nil { return e }
    if _, e := wheel(root, "bundlr-new-python", python = ">=3.13"); e != nil { return e }
    if b.binary_install(&build, "windows-x86_64", b.join(root, "foreign"), []string{"bundlr-native==1.0"}) == nil || b.binary_install(&build, "linux-x86_64", b.join(root, "wrong-python"), []string{"bundlr-new-python==1.0"}) == nil { return "Incompatible wheels or Python requirements were accepted." }
    if e := source_build_rejection(root); e != nil { return e }
    if os.set_env("UV_CACHE_DIR", b.join(root, "conflict-cache")) != nil { return "Cannot isolate resolver fixture cache." }
    selected := wheel(root, "bundlr-root", []string{"bundlr-dep==1.0"}, "2.0", code = "def main(): return 'selected Git root'\n") or_return
    if _, e := wheel(root, "bundlr-root"); e != nil { return e }
    dependency := wheel(root, "bundlr-dep", []string{"bundlr-root==1.0"}) or_return
    conflict := b.join(root, "conflict")
    if e := extract_zip(selected, conflict); e != nil { return e }
    originals := b.files_in(conflict) or_return
    hashes := make([]string, len(originals))
    for path, i in originals { hashes[i] = b.file_hash(b.join(conflict, path)) or_return }
    if root_dependencies("linux-x86_64", conflict) == nil { return "Conflicting Git root dependency cycle was accepted." }
    for path, i in originals { if !b.matches_hash(b.join(conflict, path), hashes[i]) { return "Failed resolution changed Git root files." } }
    if os.remove(dependency) != nil || os.remove(selected) != nil { return "Cannot update owned wheel fixtures." }
    if os.set_env("UV_CACHE_DIR", b.join(root, "compatible-cache")) != nil { return "Cannot isolate resolver fixture cache." }
    if _, e := wheel(root, "bundlr-dep", []string{"bundlr-root==2.0"}); e != nil { return e }
    selected = wheel(root, "bundlr-root", []string{"bundlr-dep==1.0", `bundlr-win==1.0; sys_platform == "win32"`}, "2.0", code = "def main(): return 'selected Git root'\n") or_return
    for target in b.TARGETS {
        packages := b.join(root, fmt.aprintf("identity-%s", target))
        if e := extract_zip(selected, packages); e != nil { return e }
        if e := root_dependencies(target, packages); e != nil { return e }
        module := b.text(b.join(packages, "bundlr_root.py")) or_return
        if !strings.contains(module, "selected Git root") || !os.exists(b.join(packages, "bundlr_dep.py")) || os.exists(b.join(packages, "bundlr_win.py")) != (target == "windows-x86_64") { return "Git root identity or dependency markers changed." }
    }
    if os.set_env("UV_CACHE_DIR", b.join(root, "folded-cache")) != nil { return "Cannot isolate resolver fixture cache." }
    folded := wheel(root, "bundlr-folded", []string{"bundlr-common==1.0; python_version >= '3.12' and\n sys_platform != 'unsupported'", "bundlr-win==1.0; python_version >= '3.12' and\n\tsys_platform == 'win32'"}) or_return
    if e := b.binary_install(&build, "linux-x86_64", b.join(root, "fold-control"), []string{"bundlr-folded==1.0"}); e != nil { return e }
    for target in b.TARGETS {
        packages := b.join(root, fmt.aprintf("folded-%s", target))
        if e := extract_zip(folded, packages); e != nil { return e }
        if e := root_dependencies(target, packages); e != nil { return e }
        if !os.exists(b.join(packages, "bundlr_common.py")) || os.exists(b.join(packages, "bundlr_win.py")) != (target == "windows-x86_64") { return "Folded dependency marker tokens changed." }
    }
    if e := same_version_rejection(root); e != nil { return e }
    if e := launcher_checks(runtime, root); e != nil { return e }
    fmt.println("Managed-runtime wheel, dependency-cycle, identity, marker and launcher regressions passed.")
    return nil
}
source_build_rejection :: proc(root: string) -> Error {
    source := b.join(root, "source", "bundlr_source_only-1.0")
    if e := b.mkdir(source); e != nil { return e }
    marker := b.join(root, "backend-executed")
    if e := b.write_text(b.join(source, "pyproject.toml"), "[build-system]\nrequires=[]\nbuild-backend='backend'\nbackend-path=['.']\n"); e != nil { return e }
    if e := b.write_text(b.join(source, "backend.py"), fmt.aprintf("open(%s, 'w').write('executed')\n", b.json_text(marker))); e != nil { return e }
    if e := b.write_text(b.join(source, "PKG-INFO"), "Metadata-Version: 2.3\nName: bundlr-source-only\nVersion: 1.0\n"); e != nil { return e }
    if e := command([]string{"tar", "-C", b.join(root, "source"), "-czf", b.join(root, "bundlr_source_only-1.0.tar.gz"), "bundlr_source_only-1.0"}); e != nil { return e }
    build := b.Build{}
    e := b.binary_install(&build, "linux-x86_64", b.join(root, "source-only"), []string{"bundlr-source-only==1.0"})
    return expect(e != nil && !os.exists(marker), "A dependency source build executed its backend.")
}
same_version_rejection :: proc(root: string) -> Error {
    if os.set_env("UV_CACHE_DIR", b.join(root, "substitution-cache")) != nil { return "Cannot isolate resolver fixture cache." }
    replacement := b.join(root, "bundlr_root-2.0-py3-none-any.whl")
    if os.remove(replacement) != nil { return "Cannot update owned root wheel fixture." }
    uri := file_uri(replacement) or_return
    selected := wheel(root, "bundlr-root", []string{fmt.aprintf("bundlr-root @ %s", uri)}, "2.0", code = "def main(): return 'selected Git root'\n") or_return
    packages := b.join(root, "substitution")
    if e := extract_zip(selected, packages); e != nil { return e }
    if os.remove(selected) != nil { return "Cannot update owned root wheel fixture." }
    if _, e := wheel(root, "bundlr-root", version = "2.0", code = "def main(): return 'replacement same version'\n"); e != nil { return e }
    e := root_dependencies("linux-x86_64", packages)
    return expect(e != nil && strings.contains(fmt.aprintf("%v", e), "Git root files changed"), "Same-version source substitution was accepted.")
}
launcher_checks :: proc(runtime, root: string) -> Error {
    target := b.host_target()
    for priority, i in ([2]bool{false, true}) {
        original := b.join(root, fmt.aprintf("launcher-%d", i))
        contents := resources(original, target)
        if e := b.mkdir(b.join(contents, "packages")); e != nil { return e }
        venv := b.join(contents, "runtime")
        when ODIN_OS == .Windows {
            // Windows launchers require python.exe at the runtime root. A venv
            // puts its redirector in Scripts, so use the verified runtime layout.
            files := b.files_in(runtime) or_return
            for path in files {
                destination := b.join(venv, path)
                if e := b.mkdir(filepath.dir(destination)); e != nil { return e }
                if os.copy_file(destination, b.join(runtime, path)) != nil { return "Cannot copy verified Windows launcher runtime." }
            }
        } else {
            python := b.join(runtime, b.distribution(target).executable)
            if e := command([]string{python, "-I", "-m", "venv", "--without-pip", venv}); e != nil { return e }
        }
        venv_python := b.join(venv, "python.exe") when ODIN_OS == .Windows else b.join(venv, "bin", "python3")
        module := "import json,sys\ndef main(): print(json.dumps([sys.argv,sys.flags.isolated,sys.flags.ignore_environment])); return 0\n"
        if priority {
            purelib, _, purelib_error := capture([]string{venv_python, "-I", "-c", "import sysconfig;print(sysconfig.get_path('purelib'))"})
            if purelib_error != nil { return purelib_error }
            for name, value in (map[string]string{"demo.py" = "def main(): print('runtime root')\n", "dependency.py" = "identity = 'runtime dependency'\n"}) {
                if e := b.write_text(b.join(b.trim(purelib), name), value); e != nil { return e }
            }
            if e := b.write_text(b.join(contents, "packages", "dependency.py"), "identity = 'application dependency'\n"); e != nil { return e }
            if e := b.mkdir(b.join(contents, "packages", "extra")); e != nil { return e }
            if e := b.write_text(b.join(contents, "packages", "extra", "pth_dependency.py"), "identity = 'pth dependency'\n"); e != nil { return e }
            if e := b.write_text(b.join(contents, "packages", "extra.pth"), "extra\n"); e != nil { return e }
            module = "import dependency,pth_dependency\ndef main(): print(dependency.identity,pth_dependency.identity); return 0\n"
        }
        if e := b.write_text(b.join(contents, "packages", "demo.py"), module); e != nil { return e }
        request := b.Request{"demo==1", "Demo App", "console", "demo", "3.12", []string{target}, root}
        if e := b.create_launcher(request, target, contents, b.Entry{command = "demo", module = "demo", attributes = "main"}); e != nil { return e }
        moved := b.join(root, fmt.aprintf("relocated with spaces %d", i))
        if os.rename(original, moved) != nil { return "Cannot relocate managed launcher fixture." }
        args := []string{launcher(moved, "Demo App", target), "literal spaces; $(safe)", `quoted "value"`, "", "é漢字"}
        out, stderr, e := capture(args, recipient_environment())
        if e != nil { return fmt.aprintf("Relocated launcher failed: %s%s", out, stderr) }
        if priority {
            if b.trim(out) != "application dependency pth dependency" { return "Runtime packages shadowed application packages or .pth loading failed." }
        } else {
            parsed, pe := json.parse(out, parse_integers = true)
            if pe != .None { return "Launcher did not return argument evidence." }
            values, ok := parsed.(json.Array)
            if !ok || len(values) != 3 { return "Launcher isolation evidence changed." }
            argv, argv_ok := values[0].(json.Array)
            if !argv_ok || len(argv) != len(args) { return "Launcher dropped literal arguments." }
            argv0, argv0_ok := argv[0].(string)
            if !argv0_ok || filepath.base(argv0) != "demo" { return "Launcher command identity changed." }
            for arg, index in args[1:] { if value, good := argv[index+1].(string); !good || value != arg { return "Launcher changed a literal argument." } }
            isolated, isolated_ok := values[1].(i64)
            ignored, ignored_ok := values[2].(i64)
            if !isolated_ok || !ignored_ok || isolated != 1 || ignored != 1 { return "Launcher did not isolate the bundled interpreter." }
        }
    }
    return nil
}
