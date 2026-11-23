package bundlr
import "core:strings"
foreign import lib "system:System"
foreign lib { renamex_np :: proc "c" (source, destination: cstring, flags: u32) -> i32 --- }
publish_directory :: proc(source, destination: string) -> Error {
    if renamex_np(strings.clone_to_cstring(source), strings.clone_to_cstring(destination), 4) != 0 { return "Cannot publish application directory without replacing an existing path." }
    return nil
}
