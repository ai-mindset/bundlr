import re;
import json;
import hashlib;
import from src.domain.request { PackageRequest, BUNDLR_VERSION, PYTHON_VERSION }
import from src.platform.files {
    join_path,
    stat_path,
    list_dir,
    read_text,
    write_text,
    open_file,
    read_chunk,
    close_file
}
import from src.platform.archives { tree_entries }

obj:pub EntryPoint {
    has command: str,
        kind: str,
        module: str,
        attributes: list[str],
        metadata_directory: str = "";
}

def:pub parse_entry_point(command: str, kind: str, input: str) -> EntryPoint {
    value = re.sub(r"\s+\[[^\]]+\]\s*$", "", input).strip();
    parts = value.split(":");
    if len(parts) != 2 {
        raise ValueError(f"Unsupported Python entry point: {input}");
    }
    for path in parts {
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", path)
            is None {
            raise ValueError(f"Unsupported Python entry point: {input}");
        }
    }
    return EntryPoint(
        command=command, kind=kind, module=parts[0], attributes=parts[1].split(".")
    );
}

def:pub application_entries(metadata: str, selected: str) -> list[EntryPoint] {
    result: list[EntryPoint] = [];
    section = "";
    for line in metadata.splitlines() {
        trimmed = line.strip();
        if trimmed.startswith("[") and trimmed.endswith("]") {
            section = trimmed[1:-1];
            continue;
        }
        if section != "console_scripts" and section != "gui_scripts" {
            continue;
        }
        parts = trimmed.split("=", 1);
        if len(parts) != 2 {
            continue;
        }
        name = parts[0].strip();
        if name != "" and (selected == "" or selected == name) {
            result.append(
                parse_entry_point(
                    name,
                    "console" if section == "console_scripts" else "windowed",
                    parts[1]
                )
            );
        }
    }
    return result;
}

def normalized_project_name(value: str) -> str {
    return re.sub(r"[-_.]+", "-", value).lower();
}

def:pub installed_entry_point(
    packages: str, selected: str, source_name: str = ""
) -> EntryPoint {
    matches: list[EntryPoint] = [];
    for directory in list_dir(packages) {
        if not directory.endswith(".dist-info") {
            continue;
        }
        metadata_dir = join_path(packages, directory);
        path = join_path(metadata_dir, "entry_points.txt");
        if not stat_path(path).is_file() {
            continue;
        }
        for candidate in application_entries(read_text(path), selected) {
            candidate.metadata_directory = metadata_dir;
            matches.append(candidate);
        }
    }
    if len(matches) == 0 {
        raise ValueError(
            "The package does not provide the selected application entry point."
        );
    }
    if len(matches) > 1 {
        if selected == "" {
            preferred: list[EntryPoint] = [];
            for candidate in matches {
                project = metadata_header(
                    read_text(join_path(candidate.metadata_directory, "METADATA")),
                    "Name",
                    ""
                );
                name = normalized_project_name(project);
                if name != ""
                    and normalized_project_name(candidate.command) == name
                    and (
                        source_name == ""
                        or name == normalized_project_name(source_name)
                    ) {
                    preferred.append(candidate);
                }
            }
            if len(preferred) == 1 {
                return preferred[0];
            }
        }
        names: list[str] = [];
        for candidate in matches {
            names.append(candidate.command);
        }
        raise ValueError(
            "More than one application entry point was found: "
                + ", ".join(names)
                + ". Select one with --command."
        );
    }
    return matches[0];
}

def:pub portable_git_wheel(wheel: str) {
    pure = False;
    tags = 0;
    for line in wheel.splitlines() {
        lower = line.strip().lower();
        if lower.startswith("root-is-purelib:")
            and lower.split(":", 1)[1].strip() == "true" {
            pure = True;
        }
        if lower.startswith("tag:") {
            tags += 1;
            if not lower.endswith("-none-any") {
                raise ValueError(
                    "Cross-target Git builds require a pure-Python root wheel."
                );
            }
        }
    }
    if not pure or tags == 0 {
        raise ValueError("Cross-target Git builds require a pure-Python root wheel.");
    }
}

def:pub wheel_requirements(metadata: str) -> list[str] {
    headers: list[str] = [];
    for line in metadata.splitlines() {
        if line == "" {
            break;
        }
        if (line.startswith(" ") or line.startswith("\t")) and len(headers) > 0 {
            previous = len(headers) - 1;
            headers[previous] = headers[previous] + line.lstrip();
        } else {
            headers.append(line);
        }
    }
    result: list[str] = [];
    for header in headers {
        if header.lower().startswith("requires-dist:") {
            value = header.split(":", 1)[1].strip();
            if value != "" {
                result.append(value);
            }
        }
    }
    return result;
}

def metadata_header(metadata: str, name: str, fallback: str) -> str {
    for line in metadata.splitlines() {
        if line.lower().startswith(name.lower() + ":") {
            return line.split(":", 1)[1].strip();
        }
    }
    return fallback;
}

def:pub write_manifest(
    request: PackageRequest, directory: str, target: str, point: EntryPoint
) {
    value: dict[str, str | int] = {
        "formatVersion": 1,
        "applicationName": request.applicationName,
        "applicationKind": request.applicationKind,
        "command": point.command,
        "source": request.source.value,
        "target": target,
        "pythonVersion": PYTHON_VERSION,
        "bundlrVersion": BUNDLR_VERSION
    };
    write_text(join_path(directory, "bundlr-manifest.json"), json.dumps(value) + "\n");
}

def:pub write_dependencies(directory: str, packages: str) {
    dependencies: list[dict[str, str]] = [];
    licences: list[str] = [];
    runtime_licence = join_path(directory, "runtime/LICENSE.txt");
    if stat_path(runtime_licence).is_file() {
        licences.append(
            "===== Python runtime/LICENSE.txt =====\n" + read_text(runtime_licence)
        );
    }
    for name in list_dir(packages) {
        if not name.endswith(".dist-info") {
            continue;
        }
        metadata_dir = join_path(packages, name);
        if not stat_path(metadata_dir).is_dir() {
            continue;
        }
        metadata = read_text(join_path(metadata_dir, "METADATA"));
        dependencies.append(
            {
                "name": metadata_header(metadata, "Name", name[:-10]),
                "version": metadata_header(metadata, "Version", "unknown")
            }
        );
        for file in list_dir(metadata_dir) {
            upper = file.upper();
            if upper.startswith("LICENSE")
                or upper.startswith("LICENCE")
                or upper.startswith("COPYING")
                or upper.startswith("NOTICE") {
                path = join_path(metadata_dir, file);
                if stat_path(path).is_file() {
                    licences.append(f"===== {name}/{file} =====\n" + read_text(path));
                }
            }
        }
    }
    value: dict[str, int | list[dict[str, str]]] = {
        "formatVersion": 1,
        "dependencies": dependencies
    };
    write_text(
        join_path(directory, "bundlr-dependencies.json"), json.dumps(value) + "\n"
    );
    write_text(
        join_path(directory, "THIRD_PARTY_LICENSES.txt"), "\n\n".join(licences) + "\n"
    );
}

def hash_steps(fd: int) -> Iterator[str] {
    digest = hashlib.sha256();
    while True {
        chunk = read_chunk(fd);
        if len(chunk) == 0 {
            break;
        }
        digest.update(chunk);
        yield "";
    }
    yield digest.hexdigest();
}

obj:pub HashTask {
    has path: str,
        steps: Iterator[str] | None = None,
        digest: str = "",
        done: bool = False,
        fd: int = -1;

    def start {
        self.fd = open_file(self.path);
        self.steps = hash_steps(self.fd);
    }

    def advance {
        steps = self.steps;
        if steps is None {
            raise RuntimeError("Hash operation was not started.");
        }
        value = next(steps, "");
        if value != "" {
            self.digest = value;
            self.done = True;
            self.close();
        }
    }

    def close {
        if self.fd >= 0 {
            close_file(self.fd);
            self.fd = -1;
        }
        self.steps = None;
    }
}

obj:pub EvidenceTask {
    has directory: str,
        paths: Iterator[str] | None = None,
        hashing: HashTask | None = None,
        lines: list[str] = [],
        done: bool = False;

    def start {
        self.paths = tree_entries(self.directory);
    }

    def close {
        hashing = self.hashing;
        if hashing is not None {
            hashing.close();
            self.hashing = None;
        }
        self.paths = None;
    }

    def advance {
        hashing = self.hashing;
        if hashing is not None {
            hashing.advance();
            if hashing.done {
                relative = hashing.path[len(self.directory) + 1:].replace("\\", "/");
                self.lines.append(hashing.digest + "  " + relative);
                self.hashing = None;
            }
            return;
        }
        paths = self.paths;
        if paths is None {
            raise RuntimeError("Evidence operation was not started.");
        }
        path = next(paths, "");
        if path == "" {
            self.lines.sort();
            write_text(
                join_path(self.directory, "SHA256SUMS"), "\n".join(self.lines) + "\n"
            );
            self.done = True;
            return;
        }
        if stat_path(path).is_file() {
            self.hashing = HashTask(path=path);
            self.hashing.start();
        }
    }
}
