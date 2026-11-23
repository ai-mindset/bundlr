package bundlr

import c "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "base:runtime"
import curl "https"

Download :: struct { file: ^os.File, build: ^Build, ctx: runtime.Context, failed: bool }
download_write :: proc "c" (data: rawptr, size, count: c.size_t, user: rawptr) -> c.size_t {
    d := (^Download)(user)
    context = d.ctx
    n := int(size*count)
    if check_cancel(d.build) != nil { return 0 }
    wrote, err := os.write(d.file, ([^]u8)(data)[:n])
    if err != nil || wrote != n { d.failed = true; return 0 }
    return c.size_t(wrote)
}
download_progress :: proc "c" (user: rawptr, total, now, up_total, up_now: i64) -> c.int {
    d := (^Download)(user)
    context = d.ctx
    return 1 if check_cancel(d.build) != nil else 0
}
download :: proc(b: ^Build, url, path: string) -> Error {
    f, e := os.open(path, {.Write, .Create, .Excl}, os.perm_number(0o600))
    if e != nil { return "Cannot create download file." }
    defer os.close(f)
    handle := curl.easy_init()
    if handle == nil { return "Cannot initialize HTTPS download." }
    defer curl.easy_cleanup(handle)
    d := Download{file = f, build = b, ctx = context}
    // Defaults retain certificate and hostname verification. Limit redirects to
    // HTTPS, disable signals, and provide bounded stalled-transfer timeouts.
    options_ok := true
    options_ok = options_ok && curl.easy_setopt(handle, .URL, strings.clone_to_cstring(url)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .MAXREDIRS, c.long(10)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .PROTOCOLS, c.long(2)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .REDIR_PROTOCOLS, c.long(2)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .FAILONERROR, c.long(1)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .NOSIGNAL, c.long(1)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .CONNECTTIMEOUT, c.long(30)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .LOW_SPEED_LIMIT, c.long(1)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .LOW_SPEED_TIME, c.long(60)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .WRITEFUNCTION, download_write) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .WRITEDATA, &d) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .NOPROGRESS, c.long(0)) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .XFERINFOFUNCTION, download_progress) == .E_OK
    options_ok = options_ok && curl.easy_setopt(handle, .XFERINFODATA, &d) == .E_OK
    if !options_ok { return "Cannot configure secure HTTPS download." }
    status := curl.easy_perform(handle)
    if e := check_cancel(b); e != nil { return e }
    if status != .E_OK || d.failed { return fmt.aprintf("HTTPS download failed: %s", string(curl.easy_strerror(status))) }
    return nil
}
