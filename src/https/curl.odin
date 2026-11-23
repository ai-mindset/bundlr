// Minimal bindings to the stable libcurl easy API. Linux links its versioned
// runtime SONAME; development headers and unversioned linker symlinks are not needed.
package https

import c "core:c/libc"
when ODIN_OS == .Linux { foreign import lib "system:libcurl.so.4" }
else when ODIN_OS == .Darwin { foreign import lib "system:curl" }
else when ODIN_OS == .Windows {
    // The compiler distribution ships these static libraries and their notices.
    foreign import lib {
        "vendor:curl/lib/libcurl.lib", "vendor:curl/lib/zs.lib",
        "vendor:curl/lib/brotlidec.lib", "vendor:curl/lib/brotlicommon.lib",
        "vendor:curl/lib/zstd_static.lib", "vendor:curl/lib/nghttp2.lib",
        "system:Advapi32.lib", "system:Crypt32.lib", "system:Normaliz.lib",
        "system:Secur32.lib", "system:Wldap32.lib", "system:Ws2_32.lib", "system:iphlpapi.lib",
    }
}
CURL :: struct {}
Code :: enum c.int { E_OK = 0 }
option :: enum c.int {
    WRITEDATA = 10001, URL = 10002, WRITEFUNCTION = 20011,
    LOW_SPEED_LIMIT = 19, LOW_SPEED_TIME = 20, FOLLOWLOCATION = 52,
    FAILONERROR = 45, NOPROGRESS = 43, XFERINFODATA = 10057,
    MAXREDIRS = 68, CONNECTTIMEOUT = 78, NOSIGNAL = 99,
    PROTOCOLS = 181, REDIR_PROTOCOLS = 182, XFERINFOFUNCTION = 20219,
}
GLOBAL_DEFAULT :: c.long(3)
@(default_calling_convention="c", link_prefix="curl_")
foreign lib {
    global_init :: proc(flags: c.long) -> Code ---
    global_cleanup :: proc() ---
    easy_init :: proc() -> ^CURL ---
    easy_cleanup :: proc(handle: ^CURL) ---
    easy_setopt :: proc(handle: ^CURL, option: option, #c_vararg args: ..any) -> Code ---
    easy_perform :: proc(handle: ^CURL) -> Code ---
    easy_strerror :: proc(code: Code) -> cstring ---
}
