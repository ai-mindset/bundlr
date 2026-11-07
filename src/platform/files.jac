"""Portable, exclusive file operations through libuv, without shell commands."""
import sys;
import os;
import hashlib;
import from src.platform.ffi_uv {
    Buffer,
    make_buffer,
    Dirent,
    calloc,
    free,
    checked,
    c_string,
    uv_req_size,
    uv_fs_req_cleanup,
    uv_fs_open,
    uv_fs_close,
    uv_fs_read,
    uv_fs_write,
    uv_fs_lstat,
    uv_fs_stat,
    uv_fs_get_statbuf,
    uv_fs_mkdir,
    uv_fs_mkdtemp,
    uv_fs_get_path,
    uv_fs_scandir,
    uv_fs_scandir_next,
    uv_fs_unlink,
    uv_fs_rmdir,
    uv_fs_chmod,
    uv_fs_link,
    uv_fs_rename,
    uv_fs_symlink,
    uv_fs_readlink,
    uv_fs_get_ptr,
    uv_cwd,
    uv_exepath,
    uv_random,
    uv_err_name
}

obj:pub FileInfo {
    has exists: bool = False,
        mode: int = 0,
        size: int = 0;

    def is_dir -> bool {
        return (self.mode & 61440) == 16384;
    }

    def is_file -> bool {
        return (self.mode & 61440) == 32768;
    }

    def is_link -> bool {
        return (self.mode & 61440) == 40960;
    }
}

def request -> ptr {
    return calloc(1, uv_req_size(6));
}

def finish(req: ptr) {
    uv_fs_req_cleanup(req);
    free(req);
}

def:pub join_path(parent: str, child: str) -> str {
    if parent == "" {
        return child.replace("\\", "/");
    }
    return parent.rstrip("/\\") + "/" + child.replace("\\", "/");
}

def:pub parent_path(path: str) -> str {
    normalized = path.replace("\\", "/").rstrip("/");
    pos = normalized.rfind("/");
    if pos < 0 {
        return ".";
    }
    if pos == 0 {
        return "/";
    }
    if pos == 2 and normalized[1] == ":" {
        return normalized[:3];
    }
    return normalized[:pos];
}

def:pub base_name(path: str) -> str {
    return path.replace("\\", "/").rstrip("/").split("/")[-1];
}

def:pub native_path(executable: bool = False) -> str {
    buffer = ptr[u8](calloc(32768, 1));
    size: u64 = 32767;
    try {
        code: i32 = 0;
        if executable {
            code = uv_exepath(buffer, &mut size);
        } else {
            code = uv_cwd(buffer, &mut size);
        }
        checked(code, "Resolve native path");
        return c_string(buffer).replace("\\", "/");
    } finally {
        free(buffer);
    }
}

def:pub absolute_path(path: str) -> str {
    normalized = path.replace("\\", "/");
    if normalized.startswith("/") or (len(normalized) > 2 and normalized[1] == ":") {
        return normalized;
    }
    return join_path(native_path(), normalized);
}

def:pub stat_path(path: str, follow_links: bool = False) -> FileInfo {
    req = request();
    try {
        code = uv_fs_stat(ptr(), req, path, ptr())
            if follow_links
            else uv_fs_lstat(ptr(), req, path, ptr());
        if code < 0 {
            if uv_err_name(code) == "ENOENT" or uv_err_name(code) == "ENOTDIR" {
                return FileInfo();
            }
            checked(code, f"Inspect {path}");
        }
        info = uv_fs_get_statbuf(req).view(8);
        return FileInfo(exists=True, mode=int(info[1]), size=int(info[7]));
    } finally {
        finish(req);
    }
}

def:pub require_absent(path: str) {
    if stat_path(path).exists {
        raise ValueError(f"Refusing to overwrite the existing artifact: {path}");
    }
}

def:pub make_dirs(path: str) {
    info = stat_path(path, True);
    if info.exists {
        if not info.is_dir() {
            raise ValueError(f"Not a directory: {path}");
        }
        return;
    }
    parent = parent_path(path);
    if parent != path {
        make_dirs(parent);
    }
    req = request();
    try {
        code = uv_fs_mkdir(ptr(), req, path, 493, ptr());
        if code < 0 and uv_err_name(code) != "EEXIST" {
            checked(code, f"Create directory {path}");
        }
    } finally {
        finish(req);
    }
    if not stat_path(path, True).is_dir() {
        raise ValueError(f"Not a directory: {path}");
    }
}

def:pub temp_dir(parent: str, prefix: str) -> str {
    make_dirs(parent);
    req = request();
    try {
        checked(
            uv_fs_mkdtemp(ptr(), req, join_path(parent, prefix + "XXXXXX"), ptr()),
            "Create staging directory"
        );
        return uv_fs_get_path(req);
    } finally {
        finish(req);
    }
}

def:pub list_dir(path: str) -> list[str] {
    req = request();
    try {
        checked(uv_fs_scandir(ptr(), req, path, 0, ptr()), f"Read directory {path}");
        result: list[str] = [];
        item = Dirent();
        while uv_fs_scandir_next(req, &mut item) == 0 {
            result.append(c_string(item.name));
        }
        result.sort();
        return result;
    } finally {
        finish(req);
    }
}

def:pub unlink(path: str) {
    req = request();
    try {
        checked(uv_fs_unlink(ptr(), req, path, ptr()), f"Remove {path}");
    } finally {
        finish(req);
    }
}

def:pub remove_tree(path: str) {
    info = stat_path(path);
    if not info.exists {
        return;
    }
    if not info.is_dir() {
        unlink(path);
        return;
    }
    for name in list_dir(path) {
        remove_tree(join_path(path, name));
    }
    req = request();
    try {
        checked(uv_fs_rmdir(ptr(), req, path, ptr()), f"Remove directory {path}");
    } finally {
        finish(req);
    }
}

def:pub chmod_file(path: str, mode: int) {
    req = request();
    try {
        checked(
            uv_fs_chmod(ptr(), req, path, i32(mode), ptr()),
            f"Set permissions on {path}"
        );
    } finally {
        finish(req);
    }
}

def:pub rename_file(source: str, destination: str) {
    req = request();
    try {
        checked(
            uv_fs_rename(ptr(), req, source, destination, ptr()), f"Rename {source}"
        );
    } finally {
        finish(req);
    }
}

def:pub hard_link(source: str, destination: str) {
    req = request();
    try {
        checked(
            uv_fs_link(ptr(), req, source, destination, ptr()), f"Publish {destination}"
        );
    } finally {
        finish(req);
    }
}

def:pub symlink_file(source: str, destination: str) {
    req = request();
    try {
        checked(
            uv_fs_symlink(ptr(), req, source, destination, 0, ptr()),
            f"Link {destination}"
        );
    } finally {
        finish(req);
    }
}

def:pub read_link(path: str) -> str {
    req = request();
    try {
        checked(uv_fs_readlink(ptr(), req, path, ptr()), f"Read link {path}");
        return c_string(uv_fs_get_ptr(req));
    } finally {
        finish(req);
    }
}

def write_flags(exclusive: bool) -> int {
    if sys.platform == "win32" {
        return 1 | 256 | 32768 | (1024 if exclusive else 512);
    }
    if sys.platform == "darwin" {
        return 1 | 512 | (2048 if exclusive else 1024);
    }
    return 1 | 64 | (128 if exclusive else 512);
}

def:pub open_file(path: str, writing: bool = False, exclusive: bool = True) -> int {
    req = request();
    try {
        flags = 0;
        if writing {
            flags = write_flags(exclusive);
        } elif sys.platform == "win32" {
            flags = 32768;
        }
        return checked(
            uv_fs_open(ptr(), req, path, i32(flags), 420, ptr()), f"Open {path}"
        );
    } finally {
        finish(req);
    }
}

def:pub close_file(fd: int) {
    req = request();
    try {
        checked(uv_fs_close(ptr(), req, i32(fd), ptr()), "Close file");
    } finally {
        finish(req);
    }
}

def:pub read_chunk(fd: int, maximum: int = 65536) -> bytes {
    memory = ptr[u8](calloc(u64(maximum), 1));
    req = request();
    try {
        buffer = make_buffer(memory, maximum);
        length = checked(
            uv_fs_read(ptr(), req, i32(fd), &buffer, 1, -1, ptr()), "Read file"
        );
        values: list[int] = [];
        for i in range(length) {
            values.append(int(memory.view(length)[i]));
        }
        return bytes(values);
    } finally {
        finish(req);
        free(memory);
    }
}

def:pub write_chunk(fd: int, data: bytes) {
    # bytes are copied to C-owned memory for an explicit, stable ABI boundary.
    memory = ptr[u8](calloc(u64(len(data) + 1), 1));
    try {
        view = memory.view(len(data) + 1);
        for i in range(len(data)) {
            view[i] = u8(data[i]);
        }
        offset = 0;
        while offset < len(data) {
            req = request();
            try {
                buffer = make_buffer(memory + offset, len(data) - offset);
                written = checked(
                    uv_fs_write(ptr(), req, i32(fd), &buffer, 1, -1, ptr()),
                    "Write file"
                );
                if written == 0 {
                    raise RuntimeError("File write made no progress.");
                }
                offset += written;
            } finally {
                finish(req);
            }
        }
    } finally {
        free(memory);
    }
}

def:pub read_bytes(path: str) -> bytes {
    fd = open_file(path);
    try {
        result = b"";
        while True {
            chunk = read_chunk(fd);
            if len(chunk) == 0 {
                return result;
            }
            result += chunk;
        }
    } finally {
        close_file(fd);
    }
}

def:pub read_text(path: str) -> str {
    return read_bytes(path).decode("utf-8", "replace");
}

def:pub write_bytes(path: str, data: bytes, exclusive: bool = True) {
    fd = open_file(path, True, exclusive);
    try {
        write_chunk(fd, data);
    } finally {
        close_file(fd);
    }
}

def:pub write_text(path: str, data: str, exclusive: bool = True) {
    write_bytes(path, data.encode("utf-8"), exclusive);
}

def:pub file_sha256(path: str) -> str {
    digest = hashlib.sha256();
    fd = open_file(path);
    try {
        while True {
            chunk = read_chunk(fd);
            if len(chunk) == 0 {
                return digest.hexdigest();
            }
            digest.update(chunk);
        }
    } finally {
        close_file(fd);
    }
}

def:pub random_token -> str {
    memory = ptr[u8](calloc(32, 1));
    try {
        checked(
            uv_random(ptr(), ptr(), memory, 32, 0, ptr()), "Generate session token"
        );
        digits = "0123456789abcdef";
        result = "";
        for i in range(32) {
            value = int(memory.view(32)[i]);
            result += digits[value // 16] + digits[value % 16];
        }
        return result;
    } finally {
        free(memory);
    }
}
