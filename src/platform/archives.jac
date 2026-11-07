"""Streaming archives through libarchive; all published Windows ZIPs stay classic ZIP."""
import sys;
import from src.platform.ffi_uv { calloc, free, c_string }
import from src.platform.files {
    join_path,
    parent_path,
    base_name,
    stat_path,
    list_dir,
    make_dirs,
    temp_dir,
    remove_tree,
    open_file,
    close_file,
    read_chunk,
    write_chunk,
    chmod_file,
    symlink_file,
    hard_link
}

import from .archive {
    def archive_read_new -> ptr;  def archive_read_support_format_tar(
        handle: ptr
    ) -> i32;  def archive_read_support_format_zip(handle: ptr) -> i32;  def archive_read_support_filter_gzip(
        handle: ptr
    ) -> i32;  def archive_read_open_filename(
        handle: ptr, path: str, block_size: u64
    ) -> i32;  def archive_read_next_header(handle: ptr, header: &mut ptr) -> i32;  def archive_read_data(
        handle: ptr, buffer: ptr[u8], size: u64
    ) -> i64;  def archive_read_free(handle: ptr) -> i32;  def archive_entry_pathname_utf8(
        header: ptr
    ) -> ptr[u8];  def archive_entry_symlink_utf8(header: ptr) -> ptr[u8];  def archive_entry_hardlink_utf8(
        header: ptr
    ) -> ptr[u8];  def archive_entry_filetype(header: ptr) -> u32;  def archive_entry_perm(
        header: ptr
    ) -> u32;  def archive_write_new -> ptr;  def archive_write_set_format_zip(
        handle: ptr
    ) -> i32;  def archive_write_set_format_pax_restricted(handle: ptr) -> i32;  def archive_write_add_filter_gzip(
        handle: ptr
    ) -> i32;  def archive_write_set_options(handle: ptr, options: str) -> i32;  def archive_write_open_filename(
        handle: ptr, path: str
    ) -> i32;  def archive_write_header(handle: ptr, header: ptr) -> i32;  def archive_write_data(
        handle: ptr, buffer: ptr[u8], size: u64
    ) -> i64;  def archive_write_close(handle: ptr) -> i32;  def archive_write_free(
        handle: ptr
    ) -> i32;  def archive_entry_new -> ptr;  def archive_entry_free(
        header: ptr
    ) -> None;  def archive_entry_set_pathname_utf8(header: ptr, path: str) -> None;  def archive_entry_set_filetype(
        header: ptr, kind: u32
    ) -> None;  def archive_entry_set_perm(header: ptr, mode: u32) -> None;  def archive_entry_set_size(
        header: ptr, size: i64
    ) -> None;  def archive_entry_set_mtime(
        header: ptr, seconds: i64, nanoseconds: i64
    ) -> None;  def archive_entry_set_symlink_utf8(header: ptr, target: str) -> None;  def archive_error_string(
        handle: ptr
    ) -> ptr[u8];  def archive_version_string -> str;
}

def check_archive(code: int, handle: ptr) {
    if code < 0 {
        raise RuntimeError(
            "Archive operation failed: " + c_string(archive_error_string(handle))
        );
    }
}

def:pub archive_name(name: str, strip_root: bool = False) -> str {
    value = name.replace("\\", "/");
    if value.startswith("/") or ":" in value or "\x00" in value {
        raise ValueError(f"Unsafe archive path: {name}");
    }
    parts: list[str] = [];
    for part in value.split("/") {
        if part == ".." {
            raise ValueError(f"Unsafe archive path: {name}");
        }
        if part != "" and part != "." {
            parts.append(part);
        }
    }
    if strip_root and len(parts) > 0 {
        parts = parts[1:];
    }
    return "/".join(parts);
}

def safe_link(path: str, target: str) -> str {
    if target.startswith("/") or ":" in target or "\\" in target {
        raise ValueError("Archive links must stay inside the runtime.");
    }
    parts = path.split("/")[:-1];
    for part in target.split("/") {
        if part == ".." {
            if len(parts) == 0 {
                raise ValueError("Archive link escapes the runtime.");
            }
            parts.pop();
        } elif part != "" and part != "." {
            parts.append(part);
        }
    }
    return "/".join(parts);
}

obj DeferredLink {
    has name: str,
        target: str,
        hard: bool;
}

obj:pub ArchiveMetadata {
    has modes: dict[str, int] = {},
        symlinks: dict[str, str] = {},
        executable_roots: list[str] = [],
        original_paths: dict[str, str] = {};

    def original_path(stored: str) -> str {
        return self.original_paths.get(stored, stored);
    }

    def stored_path(original: str) -> str {
        for stored in self.original_paths {
            if self.original_paths[stored] == original {
                return stored;
            }
        }
        return original;
    }
}

obj:pub Extractor {
    has source: str,
        destination: str,
        strip_root: bool = True,
        handle: ptr = ptr(),
        memory: ptr[u8] = ptr[u8](),
        fd: int = -1,
        current_path: str = "",
        current_mode: int = 420,
        done: bool = False,
        archive_done: bool = False,
        links: list[DeferredLink] = [],
        link_index: int = 0,
        metadata: ArchiveMetadata = ArchiveMetadata(),
        case_sensitive: bool | None = None,
        member_paths: dict[str, str] = {},
        host_paths: dict[str, str] = {},
        alias_index: int = 0,
        materialize_symlinks: bool = sys.platform != "win32";

    def member_path(name: str) -> str {
        if self.case_sensitive {
            return join_path(self.destination, name);
        }
        original = "";
        stored = self.destination;
        for part in name.split("/") {
            original = join_path(original, part);
            if original in self.member_paths {
                stored = self.member_paths[original];
                continue;
            }
            candidate = join_path(stored, part);
            if candidate.lower() in self.host_paths {
                # Keep both payloads on a case-insensitive builder. Archive
                # headers and evidence retain the original target names.
                while True {
                    candidate = join_path(
                        stored, "_bundlr_case_" + str(self.alias_index)
                    );
                    self.alias_index += 1;
                    if candidate.lower() not in self.host_paths
                        and not stat_path(candidate).exists {
                        break;
                    }
                }
            }
            self.member_paths[original] = candidate;
            self.host_paths[candidate.lower()] = original;
            if candidate != join_path(self.destination, original) {
                self.metadata.original_paths[candidate] = join_path(
                    self.destination, original
                );
            }
            stored = candidate;
        }
        return stored;
    }

    def start {
        make_dirs(self.destination);
        if self.case_sensitive is None {
            # Case sensitivity belongs to the destination volume, not the OS.
            probe = temp_dir(self.destination, ".bundlr-case-");
            try {
                self.case_sensitive = not stat_path(
                    join_path(self.destination, base_name(probe).upper())
                ).exists;
            } finally {
                remove_tree(probe);
            }
        }
        self.handle = archive_read_new();
        if self.handle.is_null() {
            raise RuntimeError("Could not initialize archive extraction.");
        }
        self.memory = ptr[u8](calloc(65536, 1));
        try {
            check_archive(
                int(archive_read_support_format_tar(self.handle)), self.handle
            );
            check_archive(
                int(archive_read_support_format_zip(self.handle)), self.handle
            );
            check_archive(
                int(archive_read_support_filter_gzip(self.handle)), self.handle
            );
            check_archive(
                int(archive_read_open_filename(self.handle, self.source, 65536)),
                self.handle
            );
        } except Exception {
            self.close();
            raise;
        }
    }

    def advance {
        if self.done {
            return;
        }
        if self.archive_done {
            if self.link_index < len(self.links) {
                link = self.links[self.link_index];
                destination = self.member_path(link.name);
                make_dirs(parent_path(destination));
                if link.hard {
                    target = self.member_path(link.target);
                    hard_link(target, destination);
                    self.metadata.modes[destination] = self.metadata.modes.get(
                        target, 420
                    );
                } elif self.materialize_symlinks {
                    symlink_file(self.link_target(link, destination), destination);
                }
                self.link_index += 1;
                return;
            }
            self.close();
            return;
        }
        if self.fd >= 0 {
            length = int(archive_read_data(self.handle, self.memory, 65536));
            check_archive(length, self.handle);
            if length == 0 {
                close_file(self.fd);
                self.fd = -1;
                chmod_file(self.current_path, self.current_mode);
            } else {
                values: list[int] = [];
                for i in range(length) {
                    values.append(int(self.memory.view(length)[i]));
                }
                write_chunk(self.fd, bytes(values));
            }
            return;
        }
        header: ptr = ptr();
        code = archive_read_next_header(self.handle, &mut header);
        if code == 1 {
            self.archive_done = True;
            return;
        }
        check_archive(int(code), self.handle);
        name = archive_name(
            c_string(archive_entry_pathname_utf8(header)), self.strip_root
        );
        if name == "" {
            self.metadata.modes[self.destination] = int(archive_entry_perm(header))
                & 511;
            return;
        }
        path = self.member_path(name);
        kind = int(archive_entry_filetype(header));
        mode = int(archive_entry_perm(header)) & 511;
        self.metadata.modes[path] = mode;
        hard = c_string(archive_entry_hardlink_utf8(header));
        if hard != "" {
            target_name = archive_name(hard, self.strip_root);
            self.links.append(DeferredLink(name=name, target=target_name, hard=True));
        } elif kind == 40960 {
            target_name = c_string(archive_entry_symlink_utf8(header));
            safe_link(name, target_name);
            self.metadata.symlinks[path] = target_name;
            self.links.append(DeferredLink(name=name, target=target_name, hard=False));
        } elif kind == 16384 {
            make_dirs(path);
        } elif kind == 32768 {
            make_dirs(parent_path(path));
            self.fd = open_file(path, True);
            self.current_path = path;
            self.current_mode = mode;
        } else {
            raise ValueError(f"Unsupported archive member: {name}");
        }
    }

    def link_target(link: DeferredLink, destination: str) -> str {
        name = safe_link(link.name, link.target);
        target = self.member_path(name);
        if parent_path(destination)
            == parent_path(join_path(self.destination, link.name))
            and target == join_path(self.destination, name) {
            return link.target;
        }
        # Keep a materialized Unix link usable when its parent or target has a
        # backing alias. metadata.symlinks retains the original archive target.
        parent_parts = parent_path(destination).split("/");
        target_parts = target.split("/");
        common = 0;
        while common < len(parent_parts)
            and common < len(target_parts)
            and parent_parts[common] == target_parts[common] {
            common += 1;
        }
        parts = [".."] * (len(parent_parts) - common) + target_parts[common:];
        return "/".join(parts) if len(parts) > 0 else ".";
    }

    def close {
        if self.fd >= 0 {
            close_file(self.fd);
            self.fd = -1;
        }
        if not self.handle.is_null() {
            archive_read_free(self.handle);
            self.handle = ptr();
        }
        if not self.memory.is_null() {
            free(self.memory);
            self.memory = ptr[u8]();
        }
        self.done = True;
    }
}

obj:pub PathCursor {
    has pending: list[str],
        deferred: list[str] = [],
        deferred_index: int = 0;

    def advance -> str {
        if len(self.pending) > 0 {
            path = self.pending.pop();
            if stat_path(path).is_dir() {
                names = list_dir(path);
                for index in range(len(names) - 1, -1, -1) {
                    self.pending.append(join_path(path, names[index]));
                }
            }
            return path;
        }
        while self.deferred_index < len(self.deferred) {
            path = self.deferred[self.deferred_index];
            self.deferred_index += 1;
            if not stat_path(path).exists {
                return path;
            }
        }
        return "";
    }
}

def:pub tree_entries(directory: str) -> Iterator[str] {
    cursor = PathCursor(pending=[directory]);
    while True {
        path = cursor.advance();
        if path == "" {
            return;
        }
        yield path;
    }
}

obj:pub ArchiveWriter {
    has source: str,
        destination: str,
        windows_zip: bool,
        handle: ptr = ptr(),
        memory: ptr[u8] = ptr[u8](),
        fd: int = -1,
        paths: PathCursor | None = None,
        done: bool = False,
        entry_count: int = 0,
        source_bytes: int = 0,
        metadata: ArchiveMetadata = ArchiveMetadata();

    def start {
        self.handle = archive_write_new();
        self.memory = ptr[u8](calloc(65536, 1));
        if self.handle.is_null() {
            raise RuntimeError("Could not initialize archive writer.");
        }
        try {
            if self.windows_zip {
                check_archive(
                    int(archive_write_set_format_zip(self.handle)), self.handle
                );
                check_archive(
                    int(
                        archive_write_set_options(
                            self.handle, "zip:!zip64,zip:compression=deflate"
                        )
                    ),
                    self.handle
                );
            } else {
                check_archive(
                    int(archive_write_set_format_pax_restricted(self.handle)),
                    self.handle
                );
                check_archive(
                    int(archive_write_add_filter_gzip(self.handle)), self.handle
                );
            }
            check_archive(
                int(archive_write_open_filename(self.handle, self.destination)),
                self.handle
            );
            self.paths = PathCursor(
                pending=[self.source], deferred=sorted(self.metadata.symlinks)
            );
        } except Exception {
            self.close(False);
            raise;
        }
    }

    def advance {
        if self.done {
            return;
        }
        if self.fd >= 0 {
            data = read_chunk(self.fd);
            if len(data) == 0 {
                close_file(self.fd);
                self.fd = -1;
                return;
            }
            for i in range(len(data)) {
                self.memory.view(len(data))[i] = u8(data[i]);
            }
            offset = 0;
            while offset < len(data) {
                length = int(
                    archive_write_data(
                        self.handle, self.memory + offset, u64(len(data) - offset)
                    )
                );
                check_archive(length, self.handle);
                if length == 0 {
                    raise RuntimeError("Archive write made no progress.");
                }
                offset += length;
            }
            return;
        }
        paths = self.paths;
        if paths is None {
            raise RuntimeError("Archive writer was not started.");
        }
        path = paths.advance();
        if path == "" {
            self.close(True);
            return;
        }
        info = stat_path(path);
        mode = info.mode;
        if path in self.metadata.symlinks {
            mode = 40960 | 511;
        } elif sys.platform == "win32" {
            mode = (mode & 61440) | (493 if info.is_dir() else 420);
        }
        mode = (mode & 61440) | self.metadata.modes.get(path, mode & 511);
        # Windows cannot retain the executable bit of uv-installed wheel assets.
        # Adding execute permission preserves packaged helpers without guessing
        # their names or file formats; it adds no read or write permission.
        if info.is_file() and not self.windows_zip {
            for directory in self.metadata.executable_roots {
                if path.startswith(directory.rstrip("/") + "/") {
                    mode |= 73;
                }
            }
        }
        self.entry_count += 1;
        if info.is_file() {
            self.source_bytes += info.size;
        }
        if self.windows_zip {
            check_zip_limits(self.source_bytes, self.entry_count);
        }
        original = self.metadata.original_path(path);
        name = base_name(self.source) + original[len(self.source):];
        header = archive_entry_new();
        try {
            archive_entry_set_pathname_utf8(header, name);
            archive_entry_set_filetype(header, u32(mode & 61440));
            archive_entry_set_perm(header, u32(mode & 511));
            archive_entry_set_size(header, i64(info.size if info.is_file() else 0));
            archive_entry_set_mtime(header, 0, 0);
            if path in self.metadata.symlinks {
                archive_entry_set_symlink_utf8(header, self.metadata.symlinks[path]);
            } elif info.is_link() {
                import from src.platform.files { read_link }
                archive_entry_set_symlink_utf8(header, read_link(path));
            }
            check_archive(int(archive_write_header(self.handle, header)), self.handle);
        } finally {
            archive_entry_free(header);
        }
        if info.is_file() {
            self.fd = open_file(path);
        }
    }

    def close(successful: bool = False) {
        if self.fd >= 0 {
            close_file(self.fd);
            self.fd = -1;
        }
        if not self.handle.is_null() {
            code = archive_write_close(self.handle);
            try {
                if successful {
                    check_archive(int(code), self.handle);
                }
            } finally {
                archive_write_free(self.handle);
                self.handle = ptr();
            }
        }
        if not self.memory.is_null() {
            free(self.memory);
            self.memory = ptr[u8]();
        }
        self.done = True;
    }
}

def:pub check_zip_limits(source_bytes: int, entry_count: int) {
    if source_bytes > 4294967295 - 64 * 1024 * 1024 or entry_count > 65535 {
        raise ValueError(
            "The Windows application exceeds the supported ZIP size or entry limit."
        );
    }
}
