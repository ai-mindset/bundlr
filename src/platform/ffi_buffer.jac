import from .uv {
    obj Buffer {
        has base: ptr[u8],
            length: u64;
    }
}

def:pub make_buffer(base: ptr[u8], length: int) -> Buffer {
    result = Buffer();
    result.base = base;
    result.length = u64(length);
    return result;
}
