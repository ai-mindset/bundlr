import from .uv {
    obj Buffer {
        has length: u32,
            base: ptr[u8];
    }
}

def:pub make_buffer(base: ptr[u8], length: int) -> Buffer {
    result = Buffer();
    result.base = base;
    result.length = u32(length);
    return result;
}
