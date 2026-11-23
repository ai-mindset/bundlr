package acceptance

import b "../src"
import "core:compress/deflate"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

Zip_Entry :: struct { name: string, data: []u8, mode: u32 }
u16_at :: proc(data: []u8, at: int) -> int { return int(data[at]) | int(data[at+1])<<8 }
u32_at :: proc(data: []u8, at: int) -> u32 { return u32(u16_at(data, at)) | u32(u16_at(data, at+2))<<16 }
safe_path :: proc(name: string) -> bool {
    if name == "" || b.contains_control(name) || strings.contains_any(name, "\\:") || strings.has_prefix(name, "/") { return false }
    for part in strings.split(name, "/") { if part == ".." { return false } }
    return true
}
// Independent classic ZIP decoder: central directory, prefix-relative offsets,
// CRCs, UTF-8 names, stored/deflated members and Unix file modes are checked.
read_zip :: proc(bytes: []u8) -> (entries: []Zip_Entry, failure: Error) {
    end := -1
    for at := len(bytes)-22; at >= max(0, len(bytes)-65557); at -= 1 {
        if u32_at(bytes, at) == 0x06054b50 && at+22+u16_at(bytes, at+20) == len(bytes) { end = at; break }
    }
    if end < 0 || u16_at(bytes, end+4) != 0 || u16_at(bytes, end+6) != 0 { return nil, "Invalid or split ZIP archive." }
    count := u16_at(bytes, end+10)
    directory_size, offset := int(u32_at(bytes, end+12)), int(u32_at(bytes, end+16))
    if count == 65535 || directory_size > end || offset > end-directory_size { return nil, "ZIP64 is not supported." }
    base := end-directory_size-offset
    at := base+offset
    result: [dynamic]Zip_Entry
    seen: map[string]bool
    for _ in 0..<count {
        if at < 0 || at+46 > end || u32_at(bytes, at) != 0x02014b50 { return nil, "Invalid ZIP directory." }
        flags, method := u16_at(bytes, at+8), u16_at(bytes, at+10)
        compressed, size := int(u32_at(bytes, at+20)), int(u32_at(bytes, at+24))
        length, extra, comment := u16_at(bytes, at+28), u16_at(bytes, at+30), u16_at(bytes, at+32)
        if flags&1 != 0 || size > 512*1024*1024 || at+46+length+extra+comment > end { return nil, "Unsupported ZIP entry." }
        name := string(bytes[at+46:at+46+length])
        if !safe_path(name) || seen[name] { return nil, "Unsafe or duplicate ZIP path." }
        seen[name] = true
        mode := u32_at(bytes, at+38)>>16
        if mode&0o170000 == 0o120000 { return nil, "ZIP symlinks are not supported." }
        local := base+int(u32_at(bytes, at+42))
        if local < 0 || local+30 > len(bytes) || u32_at(bytes, local) != 0x04034b50 { return nil, "Invalid ZIP local entry." }
        start := local+30+u16_at(bytes, local+26)+u16_at(bytes, local+28)
        if start > len(bytes) || compressed > len(bytes)-start { return nil, "Truncated ZIP member." }
        data := bytes[start:start+compressed]
        if method == 8 {
            inflated: [dynamic]u8
            if deflate.inflate_raw(&inflated, data, expected_output_size = size, max_output_size = 512*1024*1024) != nil { return nil, "Invalid ZIP deflate stream." }
            data = inflated[:]
        } else if method != 0 { return nil, "Unsupported ZIP compression method." }
        if len(data) != size || hash.crc32(data) != u32_at(bytes, at+16) { return nil, "ZIP CRC or size mismatch." }
        append(&result, Zip_Entry{name, data, mode})
        at += 46+length+extra+comment
    }
    if at != end { return nil, "ZIP directory length mismatch." }
    return result[:], nil
}
extract_zip :: proc(archive, destination: string) -> Error {
    bytes := read_bytes(archive) or_return
    entries := read_zip(bytes) or_return
    for entry in entries {
        path := b.join(destination, entry.name)
        if strings.has_suffix(entry.name, "/") { if e := b.mkdir(path); e != nil { return e }; continue }
        if e := b.mkdir(filepath.dir(path)); e != nil { return e }
        mode := os.perm_number(int(entry.mode&0o777))
        if mode == {} { mode = os.perm_number(0o644) }
        if e := b.write_bytes(path, entry.data, mode); e != nil { return e }
    }
    return nil
}
