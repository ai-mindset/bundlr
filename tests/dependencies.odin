#+feature dynamic-literals
package acceptance

import b "../src"
import "core:fmt"
import "core:os"
import "core:strings"

Saved_Env :: struct { key, value: string, exists: bool }
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
root_dependencies :: proc(packages: string) -> Error {
    entry := b.find_entry(packages, "fixture-cli") or_return
    build := b.Build{}
    return b.install_git_dependencies(&build, b.host_target(), packages, entry)
}
dependency_regressions :: proc(runtime: string) -> Error {
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
    if _, e := wheel(root, "bundlr-native", tag = "cp312-cp312-linux_x86_64"); e != nil { return e }
    if _, e := wheel(root, "bundlr-new-python", python = ">=3.13"); e != nil { return e }
    if b.binary_install(&build, "windows-x86_64", b.join(root, "foreign"), []string{"bundlr-native==1.0"}) == nil || b.binary_install(&build, b.host_target(), b.join(root, "wrong-python"), []string{"bundlr-new-python==1.0"}) == nil { return "Incompatible wheels or Python requirements were accepted." }
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
    if root_dependencies(conflict) == nil { return "Conflicting Git root dependency cycle was accepted." }
    for path, i in originals { if !b.matches_hash(b.join(conflict, path), hashes[i]) { return "Failed resolution changed Git root files." } }
    if os.remove(dependency) != nil || os.remove(selected) != nil { return "Cannot update owned wheel fixtures." }
    if os.set_env("UV_CACHE_DIR", b.join(root, "compatible-cache")) != nil { return "Cannot isolate resolver fixture cache." }
    if _, e := wheel(root, "bundlr-dep", []string{"bundlr-root==2.0"}); e != nil { return e }
    selected = wheel(root, "bundlr-root", []string{"bundlr-dep==1.0"}, "2.0", code = "def main(): return 'selected Git root'\n") or_return
    packages := b.join(root, "compatible")
    if e := extract_zip(selected, packages); e != nil { return e }
    if e := root_dependencies(packages); e != nil { return e }
    module := b.text(b.join(packages, "bundlr_root.py")) or_return
    if !strings.contains(module, "selected Git root") || !os.exists(b.join(packages, "bundlr_dep.py")) { return "Git root identity or dependencies changed." }
    if e := same_version_rejection(root); e != nil { return e }
    fmt.println("Dependency wheel and Git root identity regressions passed.")
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
    e := b.binary_install(&build, b.host_target(), b.join(root, "source-only"), []string{"bundlr-source-only==1.0"})
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
    e := root_dependencies(packages)
    return expect(e != nil && strings.contains(fmt.aprintf("%v", e), "Git root files changed"), "Same-version source substitution was accepted.")
}
