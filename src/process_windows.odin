package bundlr

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/windows"

// The pinned os.process_start loses empty arguments and unquoted tabs. Keep its
// Process_Desc/Process interface, but pass our command line directly to Windows.
start_process :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
    if len(desc.command) == 0 || desc.command[0] == "" || strings.contains(desc.command[0], "\"") { return {}, .Invalid_Command }
    for arg in desc.command { if strings.contains(arg, "\x00") { return {}, .Invalid_Command } }
    line := windows.utf8_to_utf16(windows_command_line(desc.command), context.allocator)
    defer delete(line)
    if len(line) == 0 || len(line) >= 32767 { return {}, .Invalid_Command }

    environment: []u16
    if desc.env != nil {
        values := make([]string, len(desc.env))
        defer delete(values)
        copy(values, desc.env)
        for value in values { if strings.contains(value, "\x00") { return {}, .Invalid_Command } }
        slice.sort_by(values, proc(a, b: string) -> bool { return strings.to_upper(a) < strings.to_upper(b) })
        environment = windows.utf8_to_utf16(fmt.aprintf("%s\x00\x00", strings.join(values, "\x00")), context.allocator)
        if len(environment) == 0 { return {}, .Invalid_Command }
    }
    defer delete(environment)
    working_directory: []u16
    if desc.working_dir != "" {
        if strings.contains(desc.working_dir, "\x00") { return {}, .Invalid_Dir }
        working_directory = windows.utf8_to_utf16(desc.working_dir, context.allocator)
        if len(working_directory) == 0 { return {}, .Invalid_Dir }
    }
    defer delete(working_directory)

    null_file, e := os.open("NUL", {.Read, .Write, .Inheritable})
    if e != nil { return {}, e }
    defer os.close(null_file)
    handles: [3]windows.HANDLE
    for file, i in ([3]^os.File{desc.stdin, desc.stdout, desc.stderr}) {
        handles[i] = windows.HANDLE(os.fd(file if file != nil else null_file))
    }
    startup := windows.STARTUPINFOW{
        cb = size_of(windows.STARTUPINFOW), dwFlags = windows.STARTF_USESTDHANDLES,
        hStdInput = handles[0], hStdOutput = handles[1], hStdError = handles[2],
    }
    process: windows.PROCESS_INFORMATION
    if !windows.CreateProcessW(nil, cstring16(raw_data(line)), nil, nil, true,
        windows.CREATE_UNICODE_ENVIRONMENT, raw_data(environment),
        cstring16(raw_data(working_directory)), &startup, &process) {
        return {}, os.Platform_Error(windows.GetLastError())
    }
    windows.CloseHandle(process.hThread)
    return os.Process{pid = int(process.dwProcessId), handle = uintptr(process.hProcess)}, nil
}

signal_cancelled: i32
console_signal :: proc "stdcall" (kind: windows.DWORD) -> windows.BOOL {
    if kind == windows.CTRL_C_EVENT || kind == windows.CTRL_BREAK_EVENT || kind == windows.CTRL_CLOSE_EVENT {
        sync.atomic_store(&signal_cancelled, 1)
        return true
    }
    return false
}
setup_signals :: proc() { _ = windows.SetConsoleCtrlHandler(console_signal, true) }
was_signalled :: proc() -> bool { return sync.atomic_load(&signal_cancelled) != 0 }
kill_tree :: proc(p: os.Process) {
    // Windows taskkill follows the subprocess tree, as in the previous builder.
    _, out, err, _ := os.process_exec({command = []string{join(env("SystemRoot"), "System32", "taskkill.exe"), "/PID", fmt.aprintf("%d", p.pid), "/T", "/F"}}, context.allocator)
    delete(out)
    delete(err)
    _ = os.process_kill(p)
}
internal_exec :: proc(args: []string) -> int {
    p, e := start_process({command = args, stdout = os.stdout, stderr = os.stderr})
    if e != nil { return 127 }
    s, we := os.process_wait(p)
    if we != nil { return 125 }
    return s.exit_code
}
