import zlib;
import json;
import from src.domain.request { PackageRequest }
import from src.core.metadata { EntryPoint }
import from src.platform.files {
    join_path,
    make_dirs,
    read_bytes,
    write_bytes,
    write_text,
    chmod_file
}

def python_launcher(point: EntryPoint, packages: str) -> str {
    return "import sys\nimport site\nimport os\n"
        + packages
        + "\n"
        # Windows locates packages using the executable path before argv[0] changes.
        + "sys.argv[0] = os.path.join(os.path.dirname(sys.argv[0]), "
        + json.dumps(point.command, ensure_ascii=False)
        + ")\n"
        + f"import {point.module} as _bundlr_module\nraise SystemExit(_bundlr_module.{'.'.join(
            point.attributes
        )}())\n";
}

def little_endian(value: int, count: int) -> bytes {
    parts: list[int] = [];
    for i in range(count) {
        parts.append((value >> (i * 8)) & 255);
    }
    return bytes(parts);
}

def:pub launcher_zip(source: str) -> bytes {
    # A single stored ZIP member, with the same fixed timestamp as the former launcher.
    name = b"__main__.py";
    data = source.encode("utf-8");
    checksum = zlib.crc32(data);
    size = len(data);
    local = b"PK\x03\x04"
        + little_endian(20, 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(10273, 2)
        + little_endian(checksum, 4)
        + little_endian(size, 4)
        + little_endian(size, 4)
        + little_endian(len(name), 2)
        + little_endian(0, 2)
        + name
        + data;
    central = b"PK\x01\x02"
        + little_endian(20, 2)
        + little_endian(20, 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(10273, 2)
        + little_endian(checksum, 4)
        + little_endian(size, 4)
        + little_endian(size, 4)
        + little_endian(len(name), 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(0, 4)
        + little_endian(0, 4)
        + name;
    return local
        + central
        + b"PK\x05\x06"
        + little_endian(0, 2)
        + little_endian(0, 2)
        + little_endian(1, 2)
        + little_endian(1, 2)
        + little_endian(len(central), 4)
        + little_endian(len(local), 4)
        + little_endian(0, 2);
}

def:pub resources_path(artifact: str, target: str) -> str {
    if target.startswith("macos-") {
        return join_path(artifact, "Contents/Resources");
    }
    return artifact;
}

def xml_escape(value: str) -> str {
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
}

def:pub create_launcher(
    request: PackageRequest, artifact: str, target: str, point: EntryPoint
) -> str {
    resources = resources_path(artifact, target);
    runtime = join_path(resources, "runtime");
    name = request.applicationName;
    if target == "windows-x86_64" {
        stub_name = "t64.exe";
        python_name = "python.exe";
        if request.applicationKind == "windowed" {
            stub_name = "w64.exe";
            python_name = "pythonw.exe";
        }
        stub = read_bytes(
            join_path(runtime, "Lib/site-packages/pip/_vendor/distlib/" + stub_name)
        );
        shebang = f"#!<launcher_dir>\\runtime\\{python_name} -I -B\n";
        main = python_launcher(
            point,
            "site.addsitedir(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), 'packages'))"
        );
        write_bytes(
            join_path(artifact, name + ".exe"),
            stub + shebang.encode("utf-8") + launcher_zip(main)
        );
        return join_path(artifact, name + ".exe");
    }
    write_text(
        join_path(resources, "bundlr_launcher.py"),
        python_launcher(
            point, "site.addsitedir(__file__.rsplit('/', 1)[0] + '/packages')"
        )
    );
    launcher = join_path(artifact, name);
    script = "#!/bin/sh\nROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n";
    if target.startswith("macos-") {
        make_dirs(join_path(artifact, "Contents/MacOS"));
        launcher = join_path(artifact, "Contents/MacOS/" + name);
        script = "#!/bin/sh\nROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")/../Resources\" && pwd)\n";
        identifier = "";
        for character in name.lower() {
            if character.isalnum() or character == "." or character == "-" {
                identifier += character;
            } else {
                identifier += "-";
            }
        }
        plist = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'
            + "<key>CFBundleExecutable</key><string>"
            + xml_escape(name)
            + "</string>"
            + "<key>CFBundleIdentifier</key><string>dev.bundlr."
            + identifier
            + "</string>"
            + "<key>CFBundleName</key><string>"
            + xml_escape(name)
            + "</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n";
        write_text(join_path(artifact, "Contents/Info.plist"), plist);
    }
    script += 'exec "$ROOT/runtime/bin/python3" -I -B "$ROOT/bundlr_launcher.py" "$@"\n';
    write_text(launcher, script);
    chmod_file(launcher, 493);
    return launcher;
}
