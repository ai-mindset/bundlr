package bundlr

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Package_Result :: struct { artifactPath, target, archivePath, checksumPath, sha256: string }
binary_install :: proc(b: ^Build, target, packages: string, requirements: []string) -> Error {
    uv := resolve_uv() or_return
    d := distribution(target)
    args: [dynamic]string
    append(&args, uv, "--no-config", "pip", "install", "--target", packages, "--python-version", PYTHON_VERSION, "--python-platform", d.triple, "--only-binary", ":all:", "--no-installer-metadata")
    append(&args, ..requirements)
    if err := run(b, args[:], install_environment()); err != nil { return err }
    return nil
}
install_git_dependencies :: proc(b: ^Build, target, packages: string, entry: Entry) -> Error {
    wheel := text(join(entry.metadata, "WHEEL")) or_return
    if err := portable_wheel(wheel); err != nil { return err }
    metadata := text(join(entry.metadata, "METADATA")) or_return
    requirements := metadata_headers(metadata, "Requires-Dist")
    if len(requirements) > 0 {
        root_requirement, pe := parse_source(fmt.aprintf("%s==%s", metadata_header(metadata, "Name"), metadata_header(metadata, "Version")))
        if pe != nil { return "Git root has unsupported Name or Version metadata." }
        requested: [dynamic]string
        append(&requested, ..requirements)
        append(&requested, root_requirement)
        // Include the root in resolution so incompatible dependency cycles fail.
        // A version pin alone cannot protect against a different source of the
        // same version, so also verify the installed root's original files.
        files := files_in(packages) or_return
        hashes := make([]string, len(files))
        for file, i in files {
            if err := check_cancel(b); err != nil { return err }
            hashes[i] = file_hash(join(packages, file)) or_return
        }
        if err := binary_install(b, target, packages, requested[:]); err != nil { return err }
        for file, i in files {
            if err := check_cancel(b); err != nil { return err }
            if !matches_hash(join(packages, file), hashes[i]) { return "Git root files changed during dependency installation; refusing to package a replacement root." }
        }
    }
    return nil
}
package_target :: proc(b: ^Build, request: Request, target: string) -> (result: Package_Result, failure: Error) {
    r := request
    base := fmt.aprintf("%s-%s", r.applicationName, target)
    artifact := base
    mac := strings.has_prefix(target, "macos-")
    if mac { artifact = fmt.aprintf("%s.app", base) }
    archive := fmt.aprintf("%s.tar.gz", base)
    if target == "windows-x86_64" { archive = fmt.aprintf("%s.zip", base) }
    result = {join(r.outputDirectory, artifact), target, join(r.outputDirectory, archive), join(r.outputDirectory, fmt.aprintf("%s.sha256", archive)), ""}
    destinations := [3]string{result.artifactPath, result.archivePath, result.checksumPath}
    for path in destinations { if err := absent(path); err != nil { return result, err } }
    if err := check_cancel(b); err != nil { return result, err }
    if err := mkdir(r.outputDirectory); err != nil { return result, err }
    stage, se := os.make_directory_temp(r.outputDirectory, ".bundlr-build-", context.allocator)
    if se != nil { return result, "Cannot stage application." }
    defer os.remove_all(stage)
    staged_artifact := join(stage, artifact)
    root := staged_artifact
    if mac { root = join(root, "Contents", "Resources") }
    packages := join(root, "packages")
    if err := mkdir(packages); err != nil { return result, err }
    log(b, "stderr", fmt.aprintf("Downloading Python %s for %s...\n", PYTHON_VERSION, target))
    if err := materialize_python(b, target, join(root, "runtime")); err != nil { return result, err }
    log(b, "stderr", fmt.aprintf("Installing target-compatible wheels for %s...\n", target))
    if is_git(r.source) {
        uv := resolve_uv() or_return
        if err := run(b, []string{uv, "--no-config", "pip", "install", "--target", packages, "--python-version", PYTHON_VERSION, "--no-deps", "--no-installer-metadata", fmt.aprintf("git+%s", r.source)}, install_environment()); err != nil { return result, err }
    } else {
        if err := binary_install(b, target, packages, []string{r.source}); err != nil { return result, err }
    }
    entry := find_entry(packages, r.command) or_return
    if is_git(r.source) {
        if err := install_git_dependencies(b, target, packages, entry); err != nil { return result, err }
    }
    r.command = entry.command
    if r.applicationKind == "auto" { r.applicationKind = entry.kind }
    if err := create_launcher(r, target, root, entry); err != nil { return result, err }
    if err := write_evidence(b, r, target, root, packages); err != nil { return result, err }
    staged_archive := join(stage, archive)
    if target == "windows-x86_64" {
        if err := create_zip(b, staged_artifact, staged_archive, artifact); err != nil { return result, err }
    } else {
        if err := run(b, []string{"tar", "-C", stage, "-czf", staged_archive, artifact}); err != nil { return result, err }
    }
    result.sha256 = file_hash(staged_archive) or_return
    staged_checksum := fmt.aprintf("%s.sha256", staged_archive)
    if err := write_text(staged_checksum, fmt.aprintf("%s  %s\n", result.sha256, filepath.base(result.archivePath))); err != nil { return result, err }
    if err := check_cancel(b); err != nil { return result, err }
    if publish_error := publish_directory(staged_artifact, result.artifactPath); publish_error != nil { return result, publish_error }
    published_archive, published_checksum := false, false
    committed := false
    defer {
        if !committed {
            if published_checksum { _ = os.remove(result.checksumPath) }
            if published_archive { _ = os.remove(result.archivePath) }
            _ = os.remove_all(result.artifactPath)
        }
    }
    if le := os.link(staged_archive, result.archivePath); le != nil { return result, "Refusing to overwrite existing archive." }
    published_archive = true
    if le := os.link(staged_checksum, result.checksumPath); le != nil { return result, "Refusing to overwrite existing checksum." }
    published_checksum = true
    if err := check_cancel(b); err != nil { return result, err }
    committed = true
    return result, nil
}
package_targets :: proc(b: ^Build, r: Request) -> (value_results: []Package_Result, failure: Error) {
    if err := validate(r); err != nil { return nil, err }
    results: [dynamic]Package_Result
    for target in r.targets {
        log(b, "stderr", fmt.aprintf("\nPackaging %s...\n", target))
        result := package_target(b, r, target) or_return
        append(&results, result)
    }
    return results[:], nil
}
