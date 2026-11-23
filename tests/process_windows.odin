package acceptance

import "core:encoding/json"
import "core:sys/windows"

descendants_stopped :: proc(marker: string) -> Error {
    data := read_bytes(marker) or_return
    pids: []int
    if json.unmarshal(data, &pids) != nil || len(pids) != 2 { return "Missing descendant identities." }
    for pid in pids {
        handle := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, u32(pid))
        if handle == nil { continue }
        code: u32
        ok := windows.GetExitCodeProcess(handle, &code)
        windows.CloseHandle(handle)
        // GetExitCodeProcess returns STILL_ACTIVE (259) for a live process.
        if !ok || code == 259 { return "Cancelled descendant is still executing." }
    }
    return nil
}
