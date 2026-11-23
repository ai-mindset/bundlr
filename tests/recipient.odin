package acceptance

import b "../src"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

BLACK_VERSION :: "26.5.1"
PACKAGING_VERSION :: "24.2"
COLORAMA_VERSION :: "0.4.6"
artifact_name :: proc(name, target: string) -> string {
    suffix := ".app" if strings.has_prefix(target, "macos-") else ""
    return fmt.aprintf("%s-%s%s", name, target, suffix)
}
resources :: proc(artifact, target: string) -> string {
    return b.join(artifact, "Contents", "Resources") if strings.has_prefix(target, "macos-") else artifact
}
launcher :: proc(artifact, name, target: string) -> string {
    if strings.has_prefix(target, "macos-") { return b.join(artifact, "Contents", "MacOS", name) }
    return b.join(artifact, fmt.aprintf("%s%s", name, ".exe" if target == "windows-x86_64" else ""))
}
verify_inventory :: proc(root: string) -> Error {
    sums := b.text(b.join(root, "SHA256SUMS")) or_return
    if b.trim(sums) == "" { return "Empty file inventory." }
    for line in strings.split_lines(sums) {
        if line == "" { continue }
        if len(line) < 67 || line[64:66] != "  " || !safe_path(line[66:]) { return "Invalid file inventory path." }
        if !b.matches_hash(b.join(root, line[66:]), line[:64]) { return fmt.aprintf("File inventory mismatch: %s", line[66:]) }
    }
    return nil
}
verify_recipient :: proc(archive, extract, name, target: string, source := "", execute := true) -> (artifact: string, failure: Error) {
    checksum := b.text(fmt.aprintf("%s.sha256", archive)) or_return
    digest := b.file_hash(archive) or_return
    if b.trim(checksum) != fmt.aprintf("%s  %s", digest, filepath.base(archive)) { return "", "Archive checksum mismatch." }
    if e := b.absent(extract); e != nil { return "", e }
    if e := b.mkdir(extract); e != nil { return "", e }
    if target == "windows-x86_64" {
        if e := extract_zip(archive, extract); e != nil { return "", e }
    } else {
        listing, stderr, listing_error := capture([]string{"tar", "-tzf", archive})
        if listing_error != nil { return "", fmt.aprintf("Cannot inspect recipient archive: %s", stderr) }
        for member in strings.split_lines(listing) { if member != "" && !safe_path(member) { return "", "Unsafe recipient tar path." } }
        if e := command([]string{"tar", "-xzf", archive, "-C", extract}); e != nil { return "", e }
    }
    artifact = b.join(extract, artifact_name(name, target))
    root := resources(artifact, target)
    data := read_bytes(b.join(root, "bundlr-manifest.json")) or_return
    manifest: b.Manifest
    if json.unmarshal(data, &manifest) != nil || manifest.target != target || manifest.pythonVersion != b.PYTHON_VERSION { return "", "Recipient manifest mismatch." }
    if source != "" && manifest.source != source { return "", "Recipient source mismatch." }
    if e := verify_inventory(root); e != nil { return "", e }
    licences := b.text(b.join(root, "THIRD_PARTY_LICENSES.txt")) or_return
    if b.trim(licences) == "" { return "", "Missing recipient licence notices." }
    if source != "" {
        inventory: b.Inventory
        metadata := read_bytes(b.join(root, "bundlr-dependencies.json")) or_return
        if json.unmarshal(metadata, &inventory) != nil { return "", "Invalid dependency inventory." }
        packaging, colorama := "", ""
        for dependency in inventory.dependencies {
            if strings.to_lower(dependency.name) == "packaging" { packaging = dependency.version }
            if strings.to_lower(dependency.name) == "colorama" { colorama = dependency.version }
        }
        if packaging != PACKAGING_VERSION || (colorama == COLORAMA_VERSION) != (target == "windows-x86_64") { return "", "Target dependency markers or versions changed." }
    }
    if execute {
        args := []string{launcher(artifact, name, target), "literal spaces; $(safe)", `quoted "value"`}
        expected := "Bundlr Git acceptance:"
        if strings.has_prefix(name, "Black") { args = []string{launcher(artifact, name, target), "--version"}; expected = fmt.aprintf("black, %s", BLACK_VERSION) }
        out, stderr, e := capture(args, recipient_environment())
        if e != nil || !strings.contains(out, expected) { return "", fmt.aprintf("Native recipient did not run independently: %s%s", out, stderr) }
    }
    return artifact, nil
}
consume :: proc(directory: string) -> Error {
    base := temporary() or_return
    defer os.remove_all(base)
    target := b.host_target()
    extension := ".zip" if target == "windows-x86_64" else ".tar.gz"
    for name in ([]string{"Black", "GitDemo"}) {
        archive := b.join(directory, fmt.aprintf("%s-%s%s", name, target, extension))
        _, e := verify_recipient(archive, b.join(base, name), name, target)
        if e != nil { return e }
    }
    fmt.println("Linux-built recipients launched without builder tools:", target)
    return nil
}
