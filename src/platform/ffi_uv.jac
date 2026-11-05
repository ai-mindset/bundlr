"""libuv's public C ABI. Handles and requests use library-reported sizes."""
import from src.platform.ffi_buffer { Buffer, make_buffer }

import from c {
    def calloc(count: u64, size: u64) -> ptr;  def malloc(size: u64) -> ptr;  def free(
        value: ptr
    ) -> None;  def strdup(value: str) -> ptr[u8];  def strlen(value: ptr[u8]) -> u64;
}

import from .uv {
    obj ProcessOptions {
        has exit_cb: Callable[[ptr, i64, i32], None],
            file: ptr[u8],
            args: ptr[ptr[u8]],
            env: ptr[ptr[u8]],
            cwd: ptr[u8],
            flags: u32,
            stdio_count: i32,
            stdio: ptr,
            uid: u32,
            gid: u32;
    }  obj Stdio {
        has flags: i32,
            data: ptr;
    }  obj Dirent {
        has name: ptr[u8],
            kind: i32;
    }  def uv_os_getpid -> i32;  def uv_version_string -> str;  def uv_default_loop -> ptr;  def uv_run(
        loop: ptr, mode: i32
    ) -> i32;  def uv_stop(loop: ptr) -> None;  def uv_loop_alive(loop: ptr) -> i32;  def uv_handle_size(
        kind: i32
    ) -> u64;  def uv_req_size(kind: i32) -> u64;  def uv_strerror(code: i32) -> str;  def uv_err_name(
        code: i32
    ) -> str;  def uv_handle_get_data(handle: ptr) -> ptr;  def uv_handle_set_data(
        handle: ptr, data: ptr
    ) -> None;  def uv_is_closing(handle: ptr) -> i32;  def uv_close(
        handle: ptr, callback: Callable[[ptr], None]
    ) -> None;  def uv_spawn(loop: ptr, handle: ptr, options: &ProcessOptions) -> i32;  def uv_process_kill(
        handle: ptr, signum: i32
    ) -> i32;  def uv_process_get_pid(handle: ptr) -> i32;  def uv_kill(
        pid: i32, signum: i32
    ) -> i32;  def uv_pipe_init(loop: ptr, pipe: ptr, ipc: i32) -> i32;  def uv_read_start(
        stream: ptr,
        alloc: Callable[[ptr, u64, &mut Buffer], None],
        read: Callable[[ptr, i64, &Buffer], None]
    ) -> i32;  def uv_read_stop(stream: ptr) -> i32;  def uv_write(
        request: ptr,
        stream: ptr,
        buffers: &Buffer,
        count: u32,
        callback: Callable[[ptr, i32], None]
    ) -> i32;  def uv_tcp_init(loop: ptr, handle: ptr) -> i32;  def uv_ip4_addr(
        ip: str, port: i32, address: ptr
    ) -> i32;  def uv_tcp_bind(handle: ptr, address: ptr, flags: u32) -> i32;  def uv_tcp_getsockname(
        handle: ptr, address: ptr, length: &mut i32
    ) -> i32;  def uv_listen(
        stream: ptr, backlog: i32, callback: Callable[[ptr, i32], None]
    ) -> i32;  def uv_accept(server: ptr, client: ptr) -> i32;  def uv_timer_init(
        loop: ptr, handle: ptr
    ) -> i32;  def uv_timer_start(
        handle: ptr, callback: Callable[[ptr], None], timeout: u64, repeat: u64
    ) -> i32;  def uv_timer_stop(handle: ptr) -> i32;  def uv_signal_init(
        loop: ptr, handle: ptr
    ) -> i32;  def uv_signal_start(
        handle: ptr, callback: Callable[[ptr, i32], None], signum: i32
    ) -> i32;  def uv_signal_stop(handle: ptr) -> i32;  def uv_cwd(
        buffer: ptr[u8], size: &mut u64
    ) -> i32;  def uv_exepath(buffer: ptr[u8], size: &mut u64) -> i32;  def uv_random(
        loop: ptr, request: ptr, buffer: ptr[u8], length: u64, flags: u32, callback: ptr
    ) -> i32;  def uv_os_environ(items: &mut ptr, count: &mut i32) -> i32;  def uv_os_free_environ(
        items: ptr, count: i32
    ) -> None;  def uv_os_uname(buffer: ptr) -> i32;  def uv_fs_req_cleanup(
        request: ptr
    ) -> None;  def uv_fs_get_path(request: ptr) -> str;  def uv_fs_get_statbuf(
        request: ptr
    ) -> ptr[u64];  def uv_fs_open(
        loop: ptr, request: ptr, path: str, flags: i32, mode: i32, callback: ptr
    ) -> i32;  def uv_fs_close(
        loop: ptr, request: ptr, fd: i32, callback: ptr
    ) -> i32;  def uv_fs_read(
        loop: ptr,
        request: ptr,
        fd: i32,
        buffers: &Buffer,
        count: u32,
        offset: i64,
        callback: ptr
    ) -> i32;  def uv_fs_write(
        loop: ptr,
        request: ptr,
        fd: i32,
        buffers: &Buffer,
        count: u32,
        offset: i64,
        callback: ptr
    ) -> i32;  def uv_fs_lstat(
        loop: ptr, request: ptr, path: str, callback: ptr
    ) -> i32;  def uv_fs_stat(
        loop: ptr, request: ptr, path: str, callback: ptr
    ) -> i32;  def uv_fs_mkdir(
        loop: ptr, request: ptr, path: str, mode: i32, callback: ptr
    ) -> i32;  def uv_fs_mkdtemp(
        loop: ptr, request: ptr, pattern: str, callback: ptr
    ) -> i32;  def uv_fs_scandir(
        loop: ptr, request: ptr, path: str, flags: i32, callback: ptr
    ) -> i32;  def uv_fs_scandir_next(request: ptr, item: &mut Dirent) -> i32;  def uv_fs_unlink(
        loop: ptr, request: ptr, path: str, callback: ptr
    ) -> i32;  def uv_fs_rmdir(
        loop: ptr, request: ptr, path: str, callback: ptr
    ) -> i32;  def uv_fs_chmod(
        loop: ptr, request: ptr, path: str, mode: i32, callback: ptr
    ) -> i32;  def uv_fs_link(
        loop: ptr, request: ptr, source: str, destination: str, callback: ptr
    ) -> i32;  def uv_fs_rename(
        loop: ptr, request: ptr, source: str, destination: str, callback: ptr
    ) -> i32;  def uv_fs_symlink(
        loop: ptr,
        request: ptr,
        source: str,
        destination: str,
        flags: i32,
        callback: ptr
    ) -> i32;  def uv_fs_readlink(
        loop: ptr, request: ptr, path: str, callback: ptr
    ) -> i32;  def uv_fs_get_ptr(request: ptr) -> ptr[u8];
}

def:pub checked(code: i32, operation: str) -> int {
    if code < 0 {
        raise RuntimeError(f"{operation}: {uv_strerror(code)}");
    }
    return int(code);
}

def:pub new_handle(kind: int) -> ptr {
    result = calloc(1, uv_handle_size(i32(kind)));
    if result.is_null() {
        raise RuntimeError("Out of memory allocating a native handle.");
    }
    return result;
}

def:pub freed(handle: ptr) {
    free(handle);
}

def:pub close_handle(handle: ptr) {
    if not handle.is_null() and uv_is_closing(handle) == 0 {
        uv_close(handle, freed);
    }
}

def:pub c_string(value: ptr[u8]) -> str {
    if value.is_null() {
        return "";
    }
    data: list[int] = [];
    for i in range(int(strlen(value))) {
        data.append(int(value.view(i + 1)[i]));
    }
    return bytes(data).decode("utf-8");
}
