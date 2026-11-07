"""Bounded-memory HTTPS downloads, advanced cooperatively by the build job."""
import from src.platform.ffi_uv { calloc, free }
import os;
import sys;
import from src.platform.files {
    open_file,
    close_file,
    write_chunk,
    join_path,
    parent_path,
    native_path
}

import from c {
    obj WriteCallback {
        has value: Callable[[ptr[u8], u64, u64, ptr], u64];
    }
}

import from .curl {
    obj CurlMessage {
        has kind: i32,
            easy: ptr,
            result: i32;
    }  def curl_global_init(flags: i64) -> i32;  def curl_easy_init -> ptr;  def curl_easy_setopt(
        handle: ptr, option: i32, *values: VaList
    ) -> i32;  def curl_easy_strerror(code: i32) -> str;  def curl_easy_cleanup(
        handle: ptr
    ) -> None;  def curl_multi_init -> ptr;  def curl_multi_add_handle(
        multi: ptr, easy: ptr
    ) -> i32;  def curl_multi_remove_handle(multi: ptr, easy: ptr) -> i32;  def curl_multi_perform(
        multi: ptr, running: &mut i32
    ) -> i32;  def curl_multi_info_read(
        multi: ptr, queued: &mut i32
    ) -> ptr[CurlMessage];  def curl_multi_cleanup(multi: ptr) -> i32;
}

glob _downloads: dict[int, Download] = {},
     _next_download: int = 1,
     _initialized: bool = False;

def receive(data: ptr[u8], size: u64, count: u64, user: ptr) -> u64 {
    task = _downloads[int(user)];
    try {
        values: list[int] = [];
        length = int(size * count);
        for i in range(length) {
            values.append(int(data.view(length)[i]));
        }
        write_chunk(task.fd, bytes(values));
        return size * count;
    } except Exception as error {
        task.error = str(error);
        return 0;
    }
}

def callback_address -> ptr {
    storage = ptr[WriteCallback](calloc(1, 8));
    try {
        storage.view(1)[0].value = receive;
        return ptr(int(ptr[u64](storage).view(1)[0]));
    } finally {
        free(storage);
    }
}

obj:pub Download {
    has url: str,
        destination: str,
        fd: int = -1,
        easy: ptr = ptr(),
        multi: ptr = ptr(),
        key: int = 0,
        done: bool = False,
        error: str = "";

    def start {
        if not _initialized {
            if curl_global_init(3) != 0 {
                raise RuntimeError("Could not initialize HTTPS support.");
            }
            _initialized = True;
        }
        self.fd = open_file(self.destination, True);
        self.easy = curl_easy_init();
        self.multi = curl_multi_init();
        self.key = _next_download;
        _next_download += 1;
        _downloads[self.key] = self;
        if self.easy.is_null() or self.multi.is_null() {
            self.close();
            raise RuntimeError("Could not initialize download.");
        }
        try {
            self.option(10002, self.url);
            ca_file = os.getenv("BUNDLR_CA_BUNDLE");
            if ca_file is not None and ca_file != "" {
                self.option(10065, ca_file);
            } elif sys.platform != "win32" {
                self.option(
                    10065, join_path(parent_path(native_path(True)), "data/cacert.pem")
                );
            }
            self.option_long(52, 1);
            self.option_long(45, 1);
            self.option_long(99, 1);
            self.option_long(78, 30);
            self.option_long(19, 1);
            self.option_long(20, 60);
            self.option_long(181, 2);
            self.option_long(182, 2);
            if curl_easy_setopt(self.easy, 20011, callback_address()) != 0 {
                raise RuntimeError("Configure download writer failed.");
            }
            if curl_easy_setopt(self.easy, 10001, ptr(self.key)) != 0 {
                raise RuntimeError("Configure download state failed.");
            }
            if curl_multi_add_handle(self.multi, self.easy) != 0 {
                raise RuntimeError("Start download failed.");
            }
        } except Exception {
            self.close();
            raise;
        }
    }

    # C variadic calls retain the concrete argument type at each call site.
    def option(option: int, value: str) {
        code = curl_easy_setopt(self.easy, i32(option), value);
        if code != 0 {
            raise RuntimeError(curl_easy_strerror(code));
        }
    }

    def option_long(option: int, value: int) {
        code = curl_easy_setopt(self.easy, i32(option), i64(value));
        if code != 0 {
            raise RuntimeError(curl_easy_strerror(code));
        }
    }

    def advance {
        if self.done {
            return;
        }
        running: i32 = 0;
        status = curl_multi_perform(self.multi, &mut running);
        if status != 0 {
            self.error = "HTTPS transfer failed.";
            self.close();
            return;
        }
        queued: i32 = 0;
        message = curl_multi_info_read(self.multi, &mut queued);
        if not message.is_null() {
            code = message.view(1)[0].result;
            if code != 0 and self.error == "" {
                self.error = curl_easy_strerror(code);
            }
            self.close();
        }
    }

    def close {
        if not self.easy.is_null() {
            if not self.multi.is_null() {
                curl_multi_remove_handle(self.multi, self.easy);
            }
            curl_easy_cleanup(self.easy);
            self.easy = ptr();
        }
        if not self.multi.is_null() {
            curl_multi_cleanup(self.multi);
            self.multi = ptr();
        }
        if self.fd >= 0 {
            close_file(self.fd);
            self.fd = -1;
        }
        if self.key != 0 {
            del _downloads[self.key];
            self.key = 0;
        }
        self.done = True;
    }
}
