import from c { def renamex_np(source: str, destination: str, flags: u32) -> i32;  }

def:pub publish_directory(source: str, destination: str) {
    if renamex_np(source, destination, 4) != 0 {
        raise RuntimeError(
            f"Could not publish {destination} without replacing an existing artifact."
        );
    }
}
