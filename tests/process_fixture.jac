import sys;
import time;
import os;
import from src.platform.files { native_path }
import from src.platform.processes { spawn_child, ProcessEvents }
import from src.platform.ffi_uv { uv_os_getpid, uv_default_loop, uv_run }

obj ForwardEvents(ProcessEvents) {
    override def stdout(text: str) {
        sys.stdout.write(text);
        sys.stdout.flush();
    }
}

glob args = sys.argv[1:];

with entry {
    if len(args) == 0 {
        sys.`exit(2);
    }
    if args[0] == "argument" {
        sys.stdout.write(args[1]);
    } elif args[0] == "stream" {
        for i in range(32) {
            sys.stdout.write("out\n");
            sys.stderr.write("err\n");
        }
    } elif args[0] == "fail" {
        sys.`exit(7);
    } elif args[0] == "sleep" {
        time.sleep(30.0);
    } elif args[0] == "tree" {
        child = spawn_child(
            native_path(True), ["descendant"], ForwardEvents(), detached=False
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
