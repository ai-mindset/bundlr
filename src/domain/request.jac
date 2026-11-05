"""Validated, runtime-independent packaging requests shared by both interfaces."""
import re;
import json;
import sys;
import from src.platform.host { host_arch }

glob:pub TARGETS: list[str] = [
         "linux-x86_64",
         "macos-arm64",
         "macos-x86_64",
         "windows-x86_64"
     ],
     PYTHON_VERSION: str = "3.12.13",
     PYTHON_BUILD: str = "20260718",
     BUNDLR_VERSION: str = "0.2.0-dev";

obj:pub PackageSource {
    has kind: str,
        value: str,
        inferred_name: str;
}

obj:pub PackageRequest {
    has source: PackageSource,
        applicationName: str = "",
        applicationKind: str = "auto",
        command: str = "",
        python: str = "3.12",
        targets: list[str] = [],
        outputDirectory: str = "dist";
}

def:pub supported_target(value: str) -> bool {
    for target in TARGETS {
        if target == value {
            return True;
        }
    }
    return False;
}

def:pub current_target -> str {
    arch = host_arch();
    if sys.platform == "win32" and arch in ["x86_64", "AMD64"] {
        return "windows-x86_64";
    }
    if sys.platform == "darwin" {
        if arch == "aarch64" or arch == "arm64" {
            return "macos-arm64";
        }
        if arch != "x86_64" {
            raise ValueError("Unsupported macOS architecture.");
        }
        return "macos-x86_64";
    }
    if sys.platform == "linux" and arch == "x86_64" {
        return "linux-x86_64";
    }
    raise ValueError(
        "Unsupported build host; use Linux x64, Windows x64, or macOS ARM64/x64."
    );
}

def:pub parse_source(input: str) -> PackageSource {
    value = input.strip();
    if value.startswith("git+") {
        value = value[4:];
        if not value.startswith("https://") {
            raise ValueError("Git URLs must use HTTPS.");
        }
    }
    if value.startswith("https://") {
        host_and_path = value[8:];
        host = host_and_path.split("/")[0];
        if host == "" or any(ord(c) <= 32 for c in value) {
            raise ValueError("Invalid HTTPS Git URL.");
        }
        path = "";
        slash = host_and_path.find("/");
        if slash >= 0 {
            path = host_and_path[slash + 1:].split("?", 1)[0].split("#", 1)[0].rstrip(
                "/"
            );
        }
        name = path.split("/")[-1].split("@", 1)[0];
        if name.endswith(".git") {
            name = name[:-4];
        }
        return PackageSource(kind="git", value=value, inferred_name=name);
    }
    if value.startswith("http://") {
        raise ValueError("Git URLs must use HTTPS.");
    }
    identifier = r"[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?";
    requirement = identifier
        + r"(\["
        + identifier
        + r"(,"
        + identifier
        + r")*\])?==[A-Za-z0-9][A-Za-z0-9.!+_-]*";
    if re.fullmatch(requirement, value) is None {
        raise ValueError(
            "Use a pinned PyPI requirement (name[extras]==version) or HTTPS Git URL."
        );
    }
    name = value.split("==", 1)[0].split("[", 1)[0];
    version = value.split("==", 1)[1];
    if re.fullmatch(
        r"v?([0-9]+!)?[0-9]+(\.[0-9]+)*([-_.]?(alpha|a|beta|b|preview|pre|rc|c)[-_.]?[0-9]*)?(-[0-9]+|[-_.]?(post|rev|r)[-_.]?[0-9]*)?([-_.]?dev[-_.]?[0-9]*)?(\+[a-z0-9]+([-_.][a-z0-9]+)*)?",
        version.lower()
    )
        is None {
        raise ValueError("The PyPI requirement must pin a valid exact version.");
    }
    return PackageSource(kind="pypi", value=value, inferred_name=name);
}

def:pub validate_request(request: PackageRequest) -> PackageRequest {
    checked_source = parse_source(request.source.value);
    if checked_source.kind != request.source.kind {
        raise ValueError("Invalid package source kind.");
    }
    request.source = checked_source;
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]*", request.applicationName) is None
        or request.applicationName != request.applicationName.strip() {
        raise ValueError(
            "Application name may contain only letters, numbers, spaces, dots, underscores, and hyphens."
        );
    }
    for text in [request.applicationName, request.outputDirectory, request.python] {
        if text == "" or text != text.strip() or "\x00" in text {
            raise ValueError(
                "Required values cannot be empty, padded, or contain NUL."
            );
        }
    }
    if request.command != request.command.strip() or "\x00" in request.command {
        raise ValueError("Invalid application command.");
    }
    if request.applicationKind != "auto"
        and request.applicationKind != "console"
        and request.applicationKind != "windowed" {
        raise ValueError("Application kind must be auto, console, or windowed.");
    }
    if request.python != "3.12" and request.python != PYTHON_VERSION {
        raise ValueError(f"Bundlr supports Python 3.12 or {PYTHON_VERSION}.");
    }
    if len(request.targets) == 0 {
        raise ValueError("Select at least one target platform.");
    }
    seen: list[str] = [];
    for selected in request.targets {
        if not supported_target(selected) {
            raise ValueError(f"Unsupported target: {selected}");
        }
        for previous in seen {
            if previous == selected {
                raise ValueError("Target platforms must be unique.");
            }
        }
        seen.append(selected);
    }
    return request;
}

def:pub parse_cli(args: list[str]) -> PackageRequest {
    values: dict[str, str] = {
        "name": "",
        "command": "",
        "kind": "auto",
        "python": "3.12",
        "output": "dist"
    };
    aliases: dict[str, str] = {
        "-n": "name",
        "--name": "name",
        "-c": "command",
        "--command": "command",
        "-k": "kind",
        "--kind": "kind",
        "-p": "python",
        "--python": "python",
        "-o": "output",
        "--output": "output"
    };
    targets: list[str] = [];
    index = 0;
    if len(args) > 0 and args[0] == "package" {
        index = 1;
    }
    while index < len(args) and args[index].startswith("-") {
        option = args[index];
        if index + 1 >= len(args)
            or args[index + 1] == ""
            or args[index + 1].startswith("-") {
            raise ValueError(f"{option} requires a value.");
        }
        value = args[index + 1];
        if option == "--target" or option == "-t" {
            if value == "all" {
                targets.extend(TARGETS);
            } else {
                targets.append(value);
            }
        } elif option in aliases {
            values[aliases[option]] = value;
        } else {
            raise ValueError(f"Unknown package option: {option}");
        }
        index += 2;
    }
    if index != len(args) - 1 {
        raise ValueError(
            "Supply exactly one PyPI requirement or HTTPS Git URL after the options."
        );
    }
    source = parse_source(args[index]);
    if len(targets) == 0 {
        targets.append(current_target());
    }
    name = values["name"];
    if name == "" {
        name = source.inferred_name;
    }
    return validate_request(
        PackageRequest(
            source=source,
            applicationName=name,
            applicationKind=values["kind"],
            command=values["command"],
            python=values["python"],
            targets=targets,
            outputDirectory=values["output"]
        )
    );
}

def json_string(value: dict[str, any], key: str, fallback: str) -> str {
    if key not in value {
        return fallback;
    }
    raw = value[key];
    if not isinstance(raw, str) {
        raise ValueError(f"{key} must be a string.");
    }
    return raw if raw != "" else fallback;
}

def:pub decode_request(body: str) -> PackageRequest {
    parsed = json.loads(body);
    if not isinstance(parsed, dict) {
        raise ValueError("Invalid package request.");
    }
    value = parsed as dict[str, any];
    if value.get("applicationKind") == "" {
        raise ValueError("Application kind must be auto, console, or windowed.");
    }
    source = parse_source(json_string(value, "source", ""));
    raw_targets = value.get("targets");
    if not isinstance(raw_targets, list) {
        raise ValueError("Select at least one target platform.");
    }
    targets: list[str] = [];
    for item in raw_targets {
        if not isinstance(item, str) {
            raise ValueError("Invalid target platform.");
        }
        targets.append(item);
    }
    return validate_request(
        PackageRequest(
            source=source,
            applicationName=json_string(value, "applicationName", source.inferred_name),
            applicationKind=json_string(value, "applicationKind", "auto"),
            command=json_string(value, "command", ""),
            python=json_string(value, "python", "3.12"),
            targets=targets,
            outputDirectory=json_string(value, "outputDirectory", "dist")
        )
    );
}
