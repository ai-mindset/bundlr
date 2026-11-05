import sys;
import from src.platform.ffi_uv {
    new_handle,
    checked,
    uv_default_loop,
    uv_signal_init,
    uv_signal_start,
    uv_signal_stop,
    close_handle
}

glob _requested: bool = False;

def on_signal(_handle: ptr, _signum: i32) {
    _requested = True;
}

def:pub cancellation_requested -> bool {
    return _requested;
}

def:pub install_signals -> list[ptr] {
    handles: list[ptr] = [];
    signals = [2];
    if sys.platform != "win32" {
        signals.append(15);
    }
    for signum in signals {
        handle = new_handle(16);
        checked(
            uv_signal_init(uv_default_loop(), handle), "Initialize cancellation signal"
        );
        checked(
            uv_signal_start(handle, on_signal, i32(signum)), "Watch cancellation signal"
        );
        handles.append(handle);
    }
    return handles;
}

def:pub remove_signals(handles: list[ptr]) {
    for handle in handles {
        uv_signal_stop(handle);
        close_handle(handle);
    }
}
