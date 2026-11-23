package bundlr

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

windows_publish_path :: proc(path: string) -> (value: string, failure: Error) {
    absolute, e := filepath.abs(path)
    if e != nil { return "", "Cannot resolve publication path." }
    absolute = replace(absolute, "/", "\\")
    if strings.has_prefix(absolute, `\\?\`) { return absolute, nil }
    if strings.has_prefix(absolute, `\\`) { return fmt.aprintf(`\\?\UNC\%s`, absolute[2:]), nil }
    return fmt.aprintf(`\\?\%s`, absolute), nil
}
publish_directory :: proc(source, destination: string) -> Error {
    source_path := windows_publish_path(source) or_return
    destination_path := windows_publish_path(destination) or_return
    src := windows.utf8_to_utf16(source_path, context.allocator)
    dst := windows.utf8_to_utf16(destination_path, context.allocator)
    if !windows.MoveFileExW(cstring16(raw_data(src)), cstring16(raw_data(dst)), 0) {
        return "Cannot publish application directory without replacing an existing path."
    }
    return nil
}
