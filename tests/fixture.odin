package acceptance

import b "../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

fixture :: proc(args: []string) -> int {
    if len(args) == 0 { return 2 }
    switch args[0] {
    case "cwd":
        if len(args) < 3 || os.set_working_directory(args[1]) != nil { return 2 }
        child, e := b.start_process({command = args[2:], stdout = os.stdout, stderr = os.stderr})
        if e != nil { return 127 }
        state, we := os.process_wait(child)
        return 125 if we != nil else state.exit_code
    case "arguments": fmt.println(b.json_text(args[1:])); return 0
    case "fail": return 37
    case "sleep": time.sleep(60*time.Second); return 0
    case "descendants":
        if len(args) < 2 { return 2 }
        child, e := b.start_process({command = []string{self(), "--fixture", "sleep"}, stdout = os.stdout, stderr = os.stderr})
        if e != nil { return 127 }
        output := os.stdout
        if len(args) > 2 && args[2] == "stderr" { output = os.stderr }
        _, _ = os.write(output, transmute([]u8)string("ready\n"))
        if b.write_text(args[1], b.json_text([]int{os.get_pid(), child.pid})) != nil { return 1 }
        if len(args) > 2 {
            bytes := strings.repeat("x", 1048576)
            _, _ = os.write(output, transmute([]u8)bytes)
        }
        time.sleep(60*time.Second)
        return 0
    case "streams":
        writer := thread.create(proc(_: ^thread.Thread) {
            bytes := make([]u8, 1048576)
            for &value in bytes { value = 'e' }
            _, _ = os.write(os.stderr, bytes)
        })
        thread.start(writer)
        bytes := make([]u8, 1048576)
        for &value in bytes { value = 'o' }
        _, _ = os.write(os.stdout, bytes)
        thread.join(writer)
        thread.destroy(writer)
        return 0
    case "process":
        b.setup_signals()
        build := b.Build{output = b.console_output}
        watch := b.Signal_Watch{build = &build}
        worker := thread.create(b.signal_watch)
        worker.data = &watch
        thread.start(worker)
        e := b.run(&build, args[1:])
        sync.atomic_store(&watch.done, true)
        thread.join(worker)
        thread.destroy(worker)
        if build.error != nil { return 1 }
        if build.cancelled { return 130 }
        return 1 if e != nil else 0
    }
    return 2
}
