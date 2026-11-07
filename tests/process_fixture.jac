import sys;
import time;
import os;
import from src.platform.files { native_path, write_chunk }
import from src.platform.processes { spawn_child, ProcessEvents }
import from src.platform.ffi_uv { uv_os_getpid, uv_default_loop, uv_run }

glob args = sys.argv[1:];

with entry {
    if len(args) == 0 {
        sys.`exit(2);
    }
    if args[0] == "argument" {
        sys.stdout.write(args[1]);
    } elif args[0] == "stream" {
        for i in range(32) {
            # Emit known bytes on every host, independently of CRT text mode.
            write_chunk(1, b"out\n");
            write_chunk(2, b"err\n");
        }
    } elif args[0] == "newlines" {
        write_chunk(1, b"out\ncrlf\r\ncr\rend");
        write_chunk(2, b"err\ncrlf\r\ncr\rend");
    } elif args[0] == "fail" {
        sys.`exit(7);
    } elif args[0] == "sleep" {
        time.sleep(30.0);
    } elif args[0] == "tree" or args[0] == "relay" {
        child = spawn_child(
            native_path(True),
            ["descendant" if args[0] == "tree" else "newlines"],
            ProcessEvents(),
            detached=False
        );
        while not child.done() {
            uv_run(uv_default_loop(), 2);
            time.sleep(0.001);
        }
        sys.`exit(child.code);
    } elif args[0] == "descendant" {
        print(str(uv_os_getpid()));
        sys.stdout.flush();
        time.sleep(30.0);
    } elif args[0] == "environment" {
        value = os.getenv("BUNDLR_TEST_VALUE");
        if value is not None {
            sys.stdout.write(value);
        }
    }
}
