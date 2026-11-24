#+build linux, darwin
package acceptance

import b "../src"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

descendants_stopped :: proc(marker: string) -> Error {
    data := read_bytes(marker) or_return
    pids: []int
    if json.unmarshal(data, &pids) != nil || len(pids) != 2 { return "Missing descendant identities." }
    for pid in pids {
        stopped := false
        started := time.tick_now()
        for time.tick_since(started) < 2*time.Second {
            if posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK { stopped = true; break }
            when ODIN_OS == .Linux {
                status, e := b.text(fmt.aprintf("/proc/%d/status", pid))
                if e == nil && strings.contains(status, "State:\tZ") { stopped = true; break }
            }
            time.sleep(10*time.Millisecond)
        }
        if !stopped { _ = posix.kill(posix.pid_t(pid), .SIGKILL); return "Cancelled descendant is still executing." }
    }
    return nil
}
check_saturated_console :: proc() -> Error {
    for stream in ([]string{"stdout", "stderr"}) {
        root := temporary() or_return
        defer os.remove_all(root)
        read, write, pe := os.pipe()
        if pe != nil { return "Cannot create saturated console pipe." }
        defer os.close(read)
        defer os.close(write)
        fd := posix.FD(os.fd(write))
        flags := posix.fcntl(fd, .GETFL, 0)
        if flags == -1 || posix.fcntl(fd, .SETFL, flags|posix.O_NONBLOCK) == -1 { return "Cannot configure owned pipe." }
        buffer: [65536]u8
        for {
            n, e := os.write(write, buffer[:])
            if e != nil || n == 0 { break }
        }
        if posix.fcntl(fd, .SETFL, flags) == -1 { return "Cannot restore owned pipe flags." }
        // Darwin exposes FWASWRITTEN through F_GETFL after the first write.
        // Compare against the prepared pipe, after our own writes and restore.
        flags = posix.fcntl(fd, .GETFL, 0)
        if flags == -1 || flags&posix.O_NONBLOCK != 0 { return "Owned console pipe is not blocking." }
        null, ne := os.open("/dev/null", {.Write})
        if ne != nil { return "Cannot open null output." }
        defer os.close(null)
        marker := b.join(root, "descendants.json")
        command := []string{self(), "--fixture", "process", self(), "--fixture", "descendants", marker, stream}
        stdout, stderr := null, null
        if strings.compare(stream, "stdout") == 0 { stdout = write } else { stderr = write }
        child, ce := b.start_process({command = command, stdout = stdout, stderr = stderr})
        if ce != nil { return "Cannot start saturated console fixture." }
        waited := false
        defer { if !waited { _ = os.process_terminate(child); _, _ = os.process_wait(child, 3*time.Second); _ = os.process_kill(child) } }
        started := time.tick_now()
        for !os.exists(marker) && time.tick_since(started) < 5*time.Second { time.sleep(10*time.Millisecond) }
        if !os.exists(marker) { return "Backend did not emit output before cancellation." }
        time.sleep(50*time.Millisecond)
        if posix.kill(posix.pid_t(child.pid), .SIGTERM) != .OK { return "Cannot signal owned console fixture." }
        state, we := os.process_wait(child, 5*time.Second)
        if we != nil { return "Cancellation stalled behind a full console pipe." }
        waited = true
        if state.exit_code != 130 { return fmt.aprintf("Cancelled %s console exited with %d; expected 130.", stream, state.exit_code) }
        if actual := posix.fcntl(fd, .GETFL, 0); actual != flags { return fmt.aprintf("Inherited %s pipe flags changed from %d to %d.", stream, flags, actual) }
        if e := descendants_stopped(marker); e != nil { return e }
    }
    fmt.println("Passed: saturated console cancellation and inherited pipe flags")
    return nil
}
