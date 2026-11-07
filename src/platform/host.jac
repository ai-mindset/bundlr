"""libuv normalizes host architecture without requiring a Python runtime."""
import from src.platform.ffi_uv { calloc, free, checked, uv_os_uname, c_string }

def:pub host_arch -> str {
    # uv_utsname_t has four documented 256-byte character arrays.
    buffer = ptr[u8](calloc(1, 1024));
    try {
        checked(uv_os_uname(buffer), "Read host architecture");
        return c_string(buffer + 768);
    } finally {
        free(buffer);
    }
}
