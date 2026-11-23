package bundlr

import "core:fmt"
import "core:os"
import "core:strings"

Entry :: struct { command, kind, module, attributes, metadata: string }
parse_entry :: proc(value: string) -> (value_entry: Entry, failure: Error) {
    v := trim(value)
    if at := strings.index(v, "["); at >= 0 {
        if !strings.has_suffix(v, "]") { return {}, "Unsupported Python entry point." }
        extras := trim(v[at+1:len(v)-1])
        if extras != "" {
            for extra in strings.split(extras, ",") {
                if !regex_match(`^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$`, trim(extra)) { return {}, "Unsupported Python entry point." }
            }
        }
        v = trim(v[:at])
    }
    parts := strings.split(v, ":")
    for &part in parts { part = trim(part) }
    if len(parts) != 2 || !regex_match(`^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$`, parts[0]) || !regex_match(`^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$`, parts[1]) {
        return {}, "Unsupported Python entry point."
    }
    return Entry{module = parts[0], attributes = parts[1]}, nil
}
application_entries :: proc(metadata, command: string) -> (value_entries: []Entry, failure: Error) {
    entries: [dynamic]Entry
    section := ""
    for line in strings.split_lines(metadata) {
        s := trim(line)
        if strings.has_prefix(s, "[") && strings.has_suffix(s, "]") { section = s[1:len(s)-1]; continue }
        if section != "console_scripts" && section != "gui_scripts" { continue }
        if s == "" || s[0] == '#' || s[0] == ';' { continue }
        eq := strings.index(s, "=")
        if eq < 1 { continue }
        name := trim(s[:eq])
        if command != "" && name != command { continue }
        e := parse_entry(s[eq+1:]) or_return
        e.command = name
        e.kind = "windowed" if section == "gui_scripts" else "console"
        append(&entries, e)
    }
    return entries[:], nil
}
find_entry :: proc(packages, command: string) -> (value_entry: Entry, failure: Error) {
    dirs, de := os.read_directory_by_path(packages, -1, context.allocator)
    if de != nil { return {}, "Cannot inspect installed packages." }
    entries: [dynamic]Entry
    for dir in dirs {
        if dir.type != .Directory || !strings.has_suffix(dir.name, ".dist-info") { continue }
        path := join(packages, dir.name, "entry_points.txt")
        data, re := os.read_entire_file(path, context.allocator)
        if re == .Not_Exist { continue }
        if re != nil { return {}, "Cannot read package entry point metadata." }
        found := application_entries(string(data), command) or_return
        for e in found {
            e := e
            e.metadata = join(packages, dir.name)
            append(&entries, e)
        }
    }
    if len(entries) == 0 { return {}, "The package does not provide the requested application entry point." }
    if len(entries) > 1 { return {}, "More than one application entry point was found. Select one with --command." }
    return entries[0], nil
}
metadata_headers :: proc(metadata: string, key: string) -> []string {
    headers: [dynamic]string
    for line in strings.split_lines(metadata) {
        if line == "" { break }
        if (line[0] == ' ' || line[0] == '\t') && len(headers) > 0 {
            headers[len(headers)-1] = fmt.aprintf("%s%s", headers[len(headers)-1], line)
        } else { append(&headers, line) }
    }
    result: [dynamic]string
    prefix := fmt.aprintf("%s:", strings.to_lower(key))
    for h in headers {
        if strings.has_prefix(strings.to_lower(h), prefix) { append(&result, trim(h[len(prefix):])) }
    }
    return result[:]
}
metadata_header :: proc(metadata, key: string) -> string {
    values := metadata_headers(metadata, key)
    return values[0] if len(values) > 0 else "unknown"
}
portable_wheel :: proc(wheel: string) -> Error {
    pure := metadata_header(wheel, "Root-Is-Purelib")
    tags := metadata_headers(wheel, "Tag")
    if strings.to_lower(pure) != "true" || len(tags) == 0 { return "Git root must produce a portable pure-Python wheel." }
    for tag in tags { if !strings.has_suffix(tag, "-none-any") { return "Git root produced a platform-specific wheel; cross-target builds require a pure-Python root." } }
    return nil
}
