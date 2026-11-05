import from src.platform.files { rename_file, require_absent }

def:pub publish_directory(source: str, destination: str) {
    # MoveFileExW (used by libuv) cannot replace a destination directory, even an empty one.
    require_absent(destination);
    rename_file(source, destination);
}
