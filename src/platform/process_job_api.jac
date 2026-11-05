"""Windows overrides these operations; Unix containment uses process groups."""
def:pub create_job(name: str) -> ptr {
    return ptr();
}

def:pub terminate_job(handle: ptr) {}
def:pub job_empty(handle: ptr) -> bool {
    return True;
}

def:pub close_job(handle: ptr) {}
def:pub enter_job(name: str) {
    raise RuntimeError("The child runner is only used on Windows.");
}
