"""Windows overrides these operations; Unix containment uses process groups."""
def:pub create_job(name: str) -> ptr {
    _ = name;
    return ptr();
}

def:pub terminate_job(handle: ptr) {
    _ = handle;
}

def:pub job_empty(handle: ptr) -> bool {
    _ = handle;
    return True;
}

def:pub close_job(handle: ptr) {
    _ = handle;
}

def:pub enter_job(name: str) {
    _ = name;
    raise RuntimeError("The child runner is only used on Windows.");
}
