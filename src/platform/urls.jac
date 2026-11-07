import from src.platform.ffi_uv { c_string }
import from .curl {
    def curl_url -> ptr;  def curl_url_set(
        handle: ptr, part: i32, value: str, flags: u32
    ) -> i32;  def curl_url_get(
        handle: ptr, part: i32, value: &mut ptr[u8], flags: u32
    ) -> i32;  def curl_url_cleanup(handle: ptr) -> None;  def curl_free(
        memory: ptr
    ) -> None;
}

def:pub validate_git_url(url: str) {
    handle = curl_url();
    if handle.is_null() {
        raise RuntimeError("Could not initialize URL validation.");
    }
    try {
        if not url.startswith("https://") or curl_url_set(handle, 0, url, 0) != 0 {
            raise ValueError("Invalid HTTPS Git URL.");
        }
        host: ptr[u8] = ptr[u8]();
        if curl_url_get(handle, 5, &mut host, 0) != 0 {
            raise ValueError("Git URL must include a valid host.");
        }
        try {
            if c_string(host) == "" {
                raise ValueError("Git URL must include a valid host.");
            }
        } finally {
            curl_free(host);
        }
    } finally {
        curl_url_cleanup(handle);
    }
}
