package bundlr

import "core:fmt"
import crc32 "core:hash"
import "core:os"
import "core:strings"

Zip :: struct { file: ^os.File, offset: u64, directory: [dynamic]u8, count: int }
le16 :: proc(b: ^[dynamic]u8, n: u16) { append(b, u8(n), u8(n>>8)) }
le32 :: proc(b: ^[dynamic]u8, n: u32) { le16(b, u16(n)); le16(b, u16(n>>16)) }
zip_write :: proc(z: ^Zip, bytes: []u8) -> Error {
    n, e := os.write(z.file, bytes)
    if e != nil || n != len(bytes) { return "Cannot finish writing ZIP archive." }
    z.offset += u64(n)
    return nil
}
zip_add :: proc(z: ^Zip, name: string, data: []u8, mode: u32 = 0o100644) -> Error {
    if z.count >= 65534 || len(name) > 65535 || u64(len(data))+z.offset+u64(len(z.directory))+u64(2*len(name))+128 >= 0xffff_ffff {
        return "The Windows application exceeds the supported ZIP size or entry limit."
    }
    if contains_control(name) || strings.has_prefix(name, "/") || strings.contains(name, "../") { return "Unsafe ZIP path." }
    crc := crc32.crc32(data)
    header: [dynamic]u8
    le32(&header, 0x04034b50)
    le16(&header, 20)
    le16(&header, 0x800) // UTF-8 names
    le16(&header, 0) // Store: simple, bounded and supported by every recipient.
    le16(&header, 0)
    le16(&header, 0x2821) // 2000-01-01
    le32(&header, crc)
    le32(&header, u32(len(data)))
    le32(&header, u32(len(data)))
    le16(&header, u16(len(name)))
    le16(&header, 0)
    offset := u32(z.offset)
    if e := zip_write(z, header[:]); e != nil { return e }
    if e := zip_write(z, transmute([]u8)name); e != nil { return e }
    if e := zip_write(z, data); e != nil { return e }
    d := &z.directory
    le32(d, 0x02014b50)
    le16(d, 0x0314)
    append(d, ..header[4:28])
    le16(d, 0)
    le16(d, 0)
    le16(d, 0)
    le16(d, 0)
    le32(d, mode<<16)
    le32(d, offset)
    append(d, ..transmute([]u8)name)
    z.count += 1
    return nil
}
zip_finish :: proc(z: ^Zip) -> Error {
    start := z.offset
    if e := zip_write(z, z.directory[:]); e != nil { return e }
    end: [dynamic]u8
    le32(&end, 0x06054b50)
    le16(&end, 0)
    le16(&end, 0)
    le16(&end, u16(z.count))
    le16(&end, u16(z.count))
    le32(&end, u32(len(z.directory)))
    le32(&end, u32(start))
    le16(&end, 0)
    return zip_write(z, end[:])
}
// All traversal uses lstat metadata and never follows symlink directories.
files_in :: proc(root: string, prefix := "") -> (value_paths: []string, failure: Error) {
    entries, re := os.read_directory_by_path(join(root, prefix), -1, context.allocator)
    if re != nil { return nil, fmt.aprintf("Cannot list %s", root) }
    paths: [dynamic]string
    for entry in entries {
        path := join(prefix, entry.name)
        if entry.type == .Directory {
            children := files_in(root, path) or_return
            append(&paths, ..children)
        } else if entry.type == .Regular { append(&paths, path) }
    }
    return paths[:], nil
}
create_zip :: proc(b: ^Build, root, dest, basename: string) -> Error {
    paths := files_in(root) or_return
    if len(paths) >= 65535 { return "The Windows application exceeds the supported ZIP entry limit." }
    f, oe := os.open(dest, {.Write, .Create, .Excl})
    if oe != nil { return "Cannot create ZIP archive." }
    defer os.close(f)
    z := Zip{file = f}
    for path in paths {
        if e := check_cancel(b); e != nil { return e }
        info, stat_error := os.stat(join(root, path), context.allocator)
        if stat_error != nil || info.size < 0 || u64(info.size)+z.offset+u64(len(z.directory))+131072 >= 0xffff_ffff { return "The Windows application exceeds the supported ZIP size limit." }
        data, re := os.read_entire_file(join(root, path), os.heap_allocator())
        if re != nil { return "Cannot read ZIP input file." }
        err := zip_add(&z, replace(join(basename, path), "\\", "/"), data, 0o100000 | transmute(u32)info.mode)
        delete(data, os.heap_allocator())
        if err != nil { return err }
    }
    return zip_finish(&z)
}
