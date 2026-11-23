package bundlr
import "core:strings"
import "core:sys/linux"
publish_directory :: proc(source, destination: string) -> Error {
    err := linux.renameat2(linux.AT_FDCWD, strings.clone_to_cstring(source), linux.AT_FDCWD, strings.clone_to_cstring(destination), {.NOREPLACE})
    if err != .NONE { return "Cannot publish application directory without replacing an existing path." }
    return nil
}
