"""Argument-array subprocesses with independent, concurrently drained output pipes."""
import sys;
import from src.platform.files { native_path, parent_path, join_path, stat_path }
import from src.platform.process_jobs { ProcessJob, create_process_job }
import from src.platform.ffi_uv {
    Buffer,
    ProcessOptions,
    Stdio,
    calloc,
    free,
    strdup,
    c_string,
    checked,
    new_handle,
    close_handle,
    uv_default_loop,
    uv_spawn,
    uv_pipe_init,
    uv_read_start,
    uv_read_stop,
    uv_process_kill,
    uv_process_get_pid,
    uv_kill,
    uv_timer_init,
    uv_timer_start,
    uv_timer_stop,
    uv_os_environ,
    uv_os_free_environ
}

obj:pub ProcessEvents {
    def stdout(text: str) {
        sys.stdout.write(text);
    }

    def stderr(text: str) {
        sys.stderr.write(text);
    }
}

obj Decoder {
    has pending: bytes = b"";

    def feed(data: bytes, final: bool = False) -> str {
        data = self.pending + data;
        cut = len(data);
        if not final and cut > 0 {
            start = cut - 1;
            while start >= 0 and start >= cut - 4 and (data[start] & 192) == 128 {
                start -= 1;
            }
            if start >= 0 {
                lead = data[start];
                width = 1;
                if lead >= 240 {
                    width = 4;
                } elif lead >= 224 {
                    width = 3;
                } elif lead >= 192 {
                    width = 2;
                }
                if cut - start < width {
                    cut = start;
                }
            }
        }
        self.pending = data[cut:];
        return data[:cut].decode("utf-8", "replace");
    }
}

obj:pub Child {
    has events: ProcessEvents,
        process_handle: ptr = ptr(),
        output_handle: ptr = ptr(),
        error_handle: ptr = ptr(),
        exited: bool = False,
        stdout_eof: bool = False,
        stderr_eof: bool = False,
        code: int = -1,
        output: str = "",
        capture: bool = False,
        cancelled: bool = False,
        pid: int = 0,
        timer: ptr = ptr(),
        decoder_out: Decoder = Decoder(),
        decoder_err: Decoder = Decoder();

    has job: ProcessJob | None = None;

    def done -> bool {
        complete = self.exited and self.stdout_eof and self.stderr_eof;
        job = self.job;
        if complete and job is not None {
            if not job.empty() {
                return False;
            }
            job.close();
            self.job = None;
        }
        if complete and not self.timer.is_null() {
            uv_timer_stop(self.timer);
            del _children[int(self.timer)];
            close_handle(self.timer);
            self.timer = ptr();
        }
        return complete;
    }

    def signal(signum: int) {
        job = self.job;
        if job is not None {
            job.terminate();
        }
        if sys.platform != "win32" and self.pid > 0 {
            uv_kill(i32(-self.pid), i32(signum));
        } elif not self.exited and not self.process_handle.is_null() {
            uv_process_kill(self.process_handle, i32(signum));
        }
    }

    def cancel {
        if self.cancelled or self.done() {
            return;
        }
        self.cancelled = True;
        self.signal(15);
        self.timer = new_handle(13);
        checked(
            uv_timer_init(uv_default_loop(), self.timer),
            "Initialize cancellation deadline"
        );
        _children[int(self.timer)] = self;
        checked(
            uv_timer_start(self.timer, cancellation_deadline, 2000, 0),
            "Schedule cancellation deadline"
        );
    }
}

glob _children: dict[int, Child] = {};

def cancellation_deadline(timer: ptr) {
    child = _children[int(timer)];
    child.signal(9);
    # Descendants can retain inherited pipes after their parent exits. Stop
    # waiting for those descriptors once cancellation's grace period expires.
    for stream in [child.output_handle, child.error_handle] {
        if int(stream) in _children {
            uv_read_stop(stream);
            del _children[int(stream)];
            close_handle(stream);
        }
    }
    child.stdout_eof = True;
    child.stderr_eof = True;
    del _children[int(timer)];
    close_handle(timer);
    child.timer = ptr();
}

def allocate(stream: ptr, suggested: u64, buffer: &mut Buffer) {
    buffer.base = ptr[u8](calloc(65536, 1));
    buffer.length = 65536;
}

def on_read(stream: ptr, count: i64, buffer: &Buffer) {
    child = _children[int(stream)];
    output_stream = stream == child.output_handle;
    decoder = child.decoder_err;
    if output_stream {
        decoder = child.decoder_out;
    }
    try {
        if count > 0 {
            data: list[int] = [];
            for i in range(int(count)) {
                data.append(int(buffer.base.view(int(count))[i]));
            }
            text = decoder.feed(bytes(data));
            if output_stream {
                if child.capture {
                    child.output += text;
                }
                child.events.stdout(text);
            } else {
                child.events.stderr(text);
            }
        } elif count < 0 {
            text = decoder.feed(b"", True);
            if output_stream {
                if child.capture {
                    child.output += text;
                }
                child.events.stdout(text);
                child.stdout_eof = True;
            } else {
                child.events.stderr(text);
                child.stderr_eof = True;
            }
            del _children[int(stream)];
            close_handle(stream);
        }
    } finally {
        free(buffer.base);
    }
}

def on_exit(handle: ptr, status: i64, signum: i32) {
    child = _children[int(handle)];
    child.code = int(status);
    if signum != 0 {
        child.code = 128 + int(signum);
    }
    child.exited = True;
    job = child.job;
    if job is not None {
        job.terminate();
    }
    child.process_handle = ptr();
    del _children[int(handle)];
    close_handle(handle);
}

def c_array(values: list[str]) -> ptr[ptr[u8]] {
    result = ptr[ptr[u8]](calloc(u64(len(values) + 1), 8));
    for i in range(len(values)) {
        result.view(len(values) + 1)[i] = strdup(values[i]);
    }
    return result;
}

def release_array(values: ptr[ptr[u8]], length: int) {
    for i in range(length) {
        free(values.view(length + 1)[i]);
    }
    free(values);
}

def environment(overrides: dict[str, str]) -> list[str] {
    items: ptr = ptr();
    count: i32 = 0;
    checked(uv_os_environ(&mut items, &mut count), "Read child environment");
    try {
        result: list[str] = [];
        pointers = ptr[ptr[u8]](items).view(int(count) * 2);
        for i in range(int(count)) {
            name = c_string(pointers[i * 2]);
            replaced = False;
            for key in overrides {
                if name == key
                    or (sys.platform == "win32" and name.upper() == key.upper()) {
                    replaced = True;
                }
            }
            if not replaced {
                result.append(name + "=" + c_string(pointers[i * 2 + 1]));
            }
        }
        for key in overrides {
            result.append(key + "=" + overrides[key]);
        }
        return result;
    } finally {
        uv_os_free_environ(items, count);
    }
}

def:pub spawn_child(
    executable: str,
    args: list[str],
    events: ProcessEvents,
    overrides: dict[str, str] | None = None,
    capture: bool = False,
    detached: bool = True
) -> Child {
    child = Child(events=events, capture=capture);
    child.process_handle = new_handle(10);
    child.output_handle = new_handle(7);
    child.error_handle = new_handle(7);
    checked(
        uv_pipe_init(uv_default_loop(), child.output_handle, 0), "Create stdout pipe"
    );
    checked(
        uv_pipe_init(uv_default_loop(), child.error_handle, 0), "Create stderr pipe"
    );
    arguments = [executable];
    arguments.extend(args);
    env = environment({} if overrides is None else overrides);
    argv = c_array(arguments);
    envp = c_array(env);
    stdio = ptr[Stdio](calloc(3, 16));
    descriptors = stdio.view(3);
    descriptors[1].flags = 33;
    descriptors[1].data = child.output_handle;
    descriptors[2].flags = 33;
    descriptors[2].data = child.error_handle;
    flags: u32 = 16;
    if sys.platform != "win32" and detached {
        flags |= 8;
    }
    options = ProcessOptions(
        exit_cb=on_exit,
        file=argv.view(len(arguments) + 1)[0],
        args=argv,
        env=envp,
        flags=flags,
        stdio_count=3,
        stdio=stdio
    );
    try {
        _children[int(child.process_handle)] = child;
        _children[int(child.output_handle)] = child;
        _children[int(child.error_handle)] = child;
        status = uv_spawn(uv_default_loop(), child.process_handle, &options);
        if status < 0 {
            del _children[int(child.process_handle)];
            del _children[int(child.output_handle)];
            del _children[int(child.error_handle)];
            close_handle(child.process_handle);
            close_handle(child.output_handle);
            close_handle(child.error_handle);
            checked(status, f"Start {executable}");
        }
        child.pid = int(uv_process_get_pid(child.process_handle));
        checked(
            uv_read_start(child.output_handle, allocate, on_read), "Read child stdout"
        );
        checked(
            uv_read_start(child.error_handle, allocate, on_read), "Read child stderr"
        );
        return child;
    } finally {
        release_array(argv, len(arguments));
        release_array(envp, len(env));
        free(stdio);
    }
}

def:pub start_child(
    executable: str,
    args: list[str],
    events: ProcessEvents,
    overrides: dict[str, str] | None = None,
    capture: bool = False,
    contain_tree: bool = True
) -> Child {
    if sys.platform != "win32" or not contain_tree {
        return spawn_child(executable, args, events, overrides, capture);
    }
    if ("/" in executable or "\\" in executable)
        and not stat_path(executable, True).is_file() {
        raise RuntimeError("Start executable: file does not exist: " + executable);
    }
    job = create_process_job();
    try {
        runner = join_path(parent_path(native_path(True)), "bundlr-child.exe");
        child = spawn_child(
            runner, [job.name, executable] + args, events, overrides, capture
        );
        child.job = job;
        return child;
    } except Exception {
        job.close();
        raise;
    }
}
