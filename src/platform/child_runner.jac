"""Join the parent-owned Windows job before spawning an untrusted build backend."""
import sys;
import time;
import from src.platform.process_jobs { enter_process_job }
import from src.platform.processes { spawn_child, ProcessEvents }
import from src.platform.ffi_uv { uv_default_loop, uv_run }

with entry {
    try {
        if len(sys.argv) < 3 {
            raise ValueError("Missing child runner arguments.");
        }
        enter_process_job(sys.argv[1]);
        child = spawn_child(sys.argv[2], sys.argv[3:], ProcessEvents());
        while not child.done() {
            uv_run(uv_default_loop(), 2);
            time.sleep(0.001);
        }
        sys.`exit(child.code);
    } except Exception as error {
        sys.stderr.write(str(error) + "\n");
        sys.`exit(1);
    }
}
