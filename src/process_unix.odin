#+build linux, darwin
package bundlr

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:sync"

start_process :: os.process_start

signal_cancelled: i32
on_signal :: proc "c" (sig: posix.Signal) { sync.atomic_store(&signal_cancelled, 1) }
setup_signals :: proc() {
    _ = posix.signal(.SIGINT, on_signal)
    _ = posix.signal(.SIGTERM, on_signal)
    _ = posix.signal(.SIGPIPE, proc "c" (_: posix.Signal) {})
}
was_signalled :: proc() -> bool { return sync.atomic_load(&signal_cancelled) != 0 }
kill_tree :: proc(p: os.Process) {
    // The exec trampoline owns a new session before executing any project code.
    // If cancellation won the race with setsid, kill the same PID directly.
    if posix.kill(-posix.pid_t(p.pid), .SIGKILL) != .OK { _ = os.process_kill(p) }
}
internal_exec :: proc(args: []string) -> int {
    if len(args) == 0 || posix.setsid() < 0 { return 125 }
    argv := make([]cstring, len(args)+1)
    for s, i in args { argv[i] = strings.clone_to_cstring(s) }
    _ = posix.execvp(argv[0], raw_data(argv))
    return 127
}
