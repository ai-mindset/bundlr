"""Linux's exclusive directory rename; there is deliberately no replacing fallback."""
import from c {
    def renameat2(
        source_dir: i32, source: str, target_dir: i32, destination: str, flags: u32
    ) -> i32;
}

def:pub publish_directory(source: str, destination: str) {
    if renameat2(-100, source, -100, destination, 1) != 0 {
        raise RuntimeError(
            f"Could not publish {destination} without replacing an existing artifact."
        );
    }
}
