package bundlr

import "core:fmt"
import "core:net"
import "core:strings"
import "core:text/regex"

TARGETS :: [4]string{"linux-x86_64", "macos-arm64", "macos-x86_64", "windows-x86_64"}
Request :: struct {
    source: string,
    applicationName: string,
    applicationKind: string,
    command: string,
    python: string,
    targets: []string,
    outputDirectory: string,
}
Distribution :: struct { triple, sha, executable: string }
DISTRIBUTIONS :: [4]Distribution {
    {"x86_64-unknown-linux-gnu", "5854aa6ec71cad00334d5065633c210b2e7feb40956767a59a91791cadcf0b79", "bin/python3"},
    {"aarch64-apple-darwin", "9a1e9e06175c10efd8378b904b07fa21bd791ab3345d7cdffeb4a76c9ff55903", "bin/python3"},
    {"x86_64-apple-darwin", "8e6b7e6533bdf746287008edf91102e7bee0a6ca1d24f16c4514237cafd706c5", "bin/python3"},
    {"x86_64-pc-windows-msvc", "0d422a1439ec308e03f47df551bc30f5994727c456e414b026d202bcda9b7c1c", "python.exe"},
}
host_target :: proc() -> string {
    when ODIN_OS == .Linux && ODIN_ARCH == .amd64 { return TARGETS[0] }
    else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 { return TARGETS[1] }
    else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 { return TARGETS[2] }
    else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 { return TARGETS[3] }
    else { return "unsupported" }
}
distribution :: proc(target: string) -> Distribution {
    values := DISTRIBUTIONS
    for t, i in TARGETS { if t == target { return values[i] } }
    panic("validated target required")
}
regex_match :: proc(pattern, value: string) -> bool {
    re, e := regex.create(pattern, {.No_Capture, .Case_Insensitive})
    if e != nil { panic(fmt.aprintf("invalid internal pattern: %v: %s", e, pattern)) }
    defer regex.destroy(re)
    _, ok := regex.match(re, value); return ok
}
is_git :: proc(s: string) -> bool { return strings.has_prefix(s, "https://") }
parse_source :: proc(input: string) -> (value: string, failure: Error) {
    s := trim(input)
    if strings.has_prefix(s, "git+") { s = s[4:] }
    if strings.has_prefix(s, "https://") || strings.has_prefix(s, "http://") {
        scheme, host, _, _, _ := net.split_url(s)
        if scheme != "https" || len(host) == 0 || contains_control(s) {
            return "", "Git URLs must use valid HTTPS."
        }
        // Credentials in URLs would be copied into support evidence and logs.
        if strings.contains(host, "@") { return "", "Use credential-free HTTPS Git URLs." }
        endpoint := host
        if strings.has_prefix(host, "[") && strings.has_suffix(host, "]") { endpoint = host[1:len(host)-1] }
        _, host_error := net.parse_hostname_or_endpoint(endpoint)
        if host_error != .None || strings.contains(host, ":-") || strings.contains(s, " ") || strings.contains(s, "\\") {
            return "", "Git URLs must use valid HTTPS."
        }
        return s, nil
    }
    identifier :: `[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?`
    pattern :: `^` + identifier + `(?:\[` + identifier + `(?:,` + identifier + `)*\])?==v?(?:[0-9]+!)?[0-9]+(?:\.[0-9]+)*(?:[-_.]?(?:alpha|a|beta|b|preview|pre|rc|c)[-_.]?[0-9]*)?(?:-[0-9]+|[-_.]?(?:post|rev|r)[-_.]?[0-9]*)?(?:[-_.]?dev[-_.]?[0-9]*)?(?:\+[a-zA-Z0-9]+(?:[-_.][a-zA-Z0-9]+)*)?$`
    if !regex_match(pattern, s) { return "", "Use a pinned PyPI requirement (name[extras]==version) or HTTPS Git URL." }
    return s, nil
}
infer_name :: proc(s: string) -> string {
    if is_git(s) {
        _, _, path, _, _ := net.split_url(s)
        p := strings.trim_right(path, "/")
        parts := strings.split(p, "/")
        name := strings.split(parts[len(parts)-1], "@")[0]
        return strings.trim_suffix(name, ".git")
    }
    end := strings.index_any(s, "[=")
    if end < 0 { return s }
    return s[:end]
}
validate :: proc(r: Request) -> Error {
    _, err := parse_source(r.source)
    if err != nil { return err }
    if !regex_match(`^[A-Za-z0-9][A-Za-z0-9 ._-]*$`, r.applicationName) || r.applicationName != trim(r.applicationName) {
        return "Application name must contain safe letters, numbers, spaces, dots, underscores or hyphens."
    }
    // Windows treats these names specially even with an extension.
    stem := strings.to_upper(strings.split(r.applicationName, ".")[0])
    if strings.has_suffix(r.applicationName, ".") || regex_match(`^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$`, stem) {
        return "Application name is reserved on Windows."
    }
    if r.applicationKind != "auto" && r.applicationKind != "console" && r.applicationKind != "windowed" { return "Application kind must be auto, console, or windowed." }
    if r.python != "3.12" && r.python != PYTHON_VERSION { return "Bundlr supports Python 3.12 or 3.12.13." }
    if r.outputDirectory == "" || r.outputDirectory != trim(r.outputDirectory) || contains_control(r.outputDirectory) { return "Output directory is required and must not contain control characters or surrounding whitespace." }
    if r.command != trim(r.command) || contains_control(r.command) { return "Invalid application command." }
    if len(r.targets) == 0 { return "Select at least one target platform." }
    seen: map[string]bool
    for t in r.targets {
        found := false
        for supported in TARGETS { if t == supported { found = true } }
        if !found { return fmt.aprintf("Unsupported target: %s", t) }
        if seen[t] { return "Target platforms must be unique." }
        seen[t] = true
    }
    return nil
}
parse_cli :: proc(args: []string) -> (r: Request, err: Error) {
    r.applicationKind = "auto"
    r.python = "3.12"
    r.outputDirectory = "dist"
    targets: [dynamic]string
    i := 0
    for i < len(args) && strings.has_prefix(args[i], "-") {
        option := args[i]
        if i+1 >= len(args) || args[i+1] == "" || strings.has_prefix(args[i+1], "-") { return r, fmt.aprintf("%s requires a value.", option) }
        value := args[i+1]
        switch option {
        case "--name", "-n": r.applicationName = value
        case "--command", "-c": r.command = value
        case "--kind", "-k": r.applicationKind = value
        case "--python", "-p": r.python = value
        case "--output", "-o": r.outputDirectory = value
        case "--target", "-t":
            if value == "all" { for t in TARGETS { append(&targets, t) } } else { append(&targets, value) }
        case: return r, fmt.aprintf("Unknown package option: %s", option)
        }
        i += 2
    }
    if i != len(args)-1 { return r, "Exactly one PyPI requirement or HTTPS Git URL is required after the options." }
    r.source = parse_source(args[i]) or_return
    if r.applicationName == "" { r.applicationName = infer_name(r.source) }
    if len(targets) == 0 { append(&targets, host_target()) }
    r.targets = targets[:]
    return r, validate(r)
}
