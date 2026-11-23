package bundlr

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

process_mutex: sync.Mutex

// Quote every argument using the Windows CRT rules. Backslashes are doubled
// only before a quote, including the closing quote, so empty arguments, tabs,
// literal quotes and trailing backslashes survive both process boundaries.
windows_command_line :: proc(args: []string) -> string {
    line := strings.builder_make()
    for arg, i in args {
        if i > 0 { strings.write_byte(&line, ' ') }
        strings.write_byte(&line, '"')
        slashes := 0
        for c in transmute([]u8)arg {
            if c == '\\' { slashes += 1; continue }
            count := slashes
            if c == '"' { count = 2*slashes+1 }
            for _ in 0..<count { strings.write_byte(&line, '\\') }
            strings.write_byte(&line, c)
            slashes = 0
        }
        for _ in 0..<2*slashes { strings.write_byte(&line, '\\') }
        strings.write_byte(&line, '"')
    }
    return strings.to_string(line)
}

// Poll both pipes, draining output before reaping. Neither a full stderr pipe nor
// a slow browser can hide an exit or grow an unbounded output queue.
run :: proc(b: ^Build, command: []string, environment: []string = nil) -> Error {
    if e := check_cancel(b); e != nil { return e }
    out_r, out_w, pe := os.pipe()
    if pe != nil { return "Cannot create process output pipe." }
    defer os.close(out_r)
    err_r, err_w, ee := os.pipe()
    if ee != nil { os.close(out_w); return "Cannot create process error pipe." }
    defer os.close(err_r)
    executable, xe := os.get_executable_path(context.allocator)
    if xe != nil { os.close(out_w); os.close(err_w); return "Cannot locate Bundlr executable." }
    wrapped: [dynamic]string
    append(&wrapped, executable, "--internal-exec")
    append(&wrapped, ..command)
    sync.mutex_lock(&process_mutex)
    p, se := start_process({command = wrapped[:], env = environment, stdout = out_w, stderr = err_w})
    os.close(out_w)
    os.close(err_w)
    sync.mutex_unlock(&process_mutex)
    if se != nil { return fmt.aprintf("Cannot start subprocess: %v", se) }
    finished := [2]bool{}
    pipes := [2]^os.File{out_r, err_r}
    streams := [2]string{"stdout", "stderr"}
    killed := false
    state: os.Process_State
    reaped := false
    defer {
        if !reaped { kill_tree(p); _, _ = os.process_wait(p) }
    }
    for !finished[0] || !finished[1] || !reaped {
        if check_cancel(b) != nil && !killed { kill_tree(p); killed = true }
        activity := false
        for pipe, i in pipes {
            if finished[i] { continue }
            ready, re := os.pipe_has_data(pipe)
            if re == .EOF || re == .Broken_Pipe { finished[i] = true; continue }
            if re != nil { return "Cannot poll subprocess output." }
            if ready {
                buf: [16384]u8
                n, read_err := os.read(pipe, buf[:])
                if n > 0 { log(b, streams[i], string(buf[:n])); activity = true }
                if read_err == .EOF || read_err == .Broken_Pipe { finished[i] = true }
                else if read_err != nil { return "Cannot read subprocess output." }
            }
        }
        if !reaped {
            s, we := os.process_wait(p, 0)
            if we == nil && s.exited { state = s; reaped = true }
            else if we != nil && we != .Timeout { return "Cannot wait for subprocess." }
        }
        if !activity { time.sleep(5*time.Millisecond) }
    }
    if e := check_cancel(b); e != nil { return e }
    if state.exit_code != 0 || !state.success { return fmt.aprintf("Subprocess failed (exit %d).", state.exit_code) }
    return nil
}
install_environment :: proc() -> []string {
    inherited, _ := os.environ(context.allocator)
    result: [dynamic]string
    for s in inherited {
        if strings.has_prefix(s, "UV_NO_SYSTEM_CONFIG=") || strings.has_prefix(s, "UV_PYTHON_PREFERENCE=") || strings.has_prefix(s, "UV_LINK_MODE=") { continue }
        append(&result, s)
    }
    append(&result, "UV_NO_SYSTEM_CONFIG=1", "UV_PYTHON_PREFERENCE=only-managed", "UV_LINK_MODE=copy")
    return result[:]
}
