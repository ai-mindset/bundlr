"""Exercise released builders and recipients with pinned PyPI and local Git fixtures."""
import json;
import os;
import time;
import sys;
comptime import from jaclang.comptime { embed_file }
comptime ACCEPTANCE_LOCK: str = embed_file("../build-lock.json");
import from src.domain.request { current_target, TARGETS }
import from src.platform.files {
    join_path,
    parent_path,
    absolute_path,
    make_dirs,
    write_text,
    read_text,
    file_sha256,
    stat_path,
    list_dir
}
import from src.platform.processes { start_child, ProcessEvents }
import from src.platform.ffi_uv { uv_default_loop, uv_run }
import from src.platform.archives { Extractor }

glob GIT_SOURCE: str = "https://bundlr-acceptance.invalid/application.git",
     BLACK_VERSION: str = str(
         json.loads(ACCEPTANCE_LOCK)["acceptance"]["blackVersion"]
     ),
     PACKAGING_VERSION: str = str(
         json.loads(ACCEPTANCE_LOCK)["acceptance"]["packagingVersion"]
     ),
     COLORAMA_VERSION: str = str(
         json.loads(ACCEPTANCE_LOCK)["acceptance"]["coloramaVersion"]
     );

obj AcceptanceEvents(ProcessEvents) {
    has errors: str = "";

    override def stderr(text: str) {
        self.errors += text;
        sys.stderr.write(text);
    }
}

def run(
    args: list[str], environment: dict[str, str] | None = None, success: bool = True
) -> str {
    events = AcceptanceEvents();
    child = start_child(args[0], args[1:], events, environment, True);
    deadline = time.monotonic() + 900.0;
    while not child.done() {
        uv_run(uv_default_loop(), 2);
        if time.monotonic() > deadline {
            child.cancel();
        }
        time.sleep(0.001);
    }
    if (child.code == 0) != success or time.monotonic() > deadline {
        raise RuntimeError(
            "Unexpected child result for " + str(args) + ": " + str(child.code)
        );
    }
    return child.output + events.errors;
}

def fixture_source -> str {
    return """import os
import sys
import subprocess
from pathlib import Path

def main():
    assert Path(sys.argv[0]).name == 'git-demo', sys.argv
    assert Path(sys.argv[0]).parent == Path(__file__).parent.parent, sys.argv
    assert sys.argv[1:] == ['literal spaces; $(safe)', 'quoted "value"'], sys.argv
    import packaging
    if sys.platform == 'win32':
        import colorama
        assert colorama.__version__ == '0.4.6'
    assert packaging.__version__ == '24.2'
    if sys.platform != 'win32':
        subprocess.run([str(Path(__file__).with_name('packaged-helper'))], check=True)
    print('Bundlr Git acceptance: ' + sys.platform)
    return 0

def window():
    assert Path(sys.argv[0]).name == 'git-window', sys.argv
    assert Path(sys.argv[0]).parent == Path(__file__).parent.parent, sys.argv
    assert sys.argv[1:] == [], sys.argv
    import tkinter
    root = tkinter.Tk()
    root.title('Bundlr GUI acceptance')
    tkinter.Label(root, text='Bundlr GUI acceptance').pack()
    def complete():
        Path(os.environ['BUNDLR_GUI_MARKER']).write_text('tkinter event loop passed')
        root.destroy()
    root.after(100, complete)
    root.mainloop()
    return 0
""".replace(
        "24.2", PACKAGING_VERSION
    ).replace(
        "0.4.6", COLORAMA_VERSION
    );
}

def git_fixture(directory: str, portable: bool) -> tuple[str, dict[str, str]] {
    make_dirs(directory);
    write_text(
        join_path(directory, "pyproject.toml"),
        '[build-system]\nrequires = []\nbuild-backend = "backend"\nbackend-path = ["."]\n'
    );
    write_text(join_path(directory, "application.py"), fixture_source());
    backend = """from pathlib import Path
import base64
import hashlib
import zipfile

def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    name = 'bundlr_acceptance-1.0.0-py3-none-any.whl'
    info = 'bundlr_acceptance-1.0.0.dist-info/'
    files = {
        'application.py': Path(__file__).with_name('application.py').read_bytes(),
        'packaged-helper': b'#!/bin/sh\\necho "Packaged executable helper passed"\\n',
        info + 'METADATA': b'Metadata-Version: 2.3\\nName: bundlr-acceptance\\nVersion: 1.0.0\\nRequires-Python: >=3.12\\nRequires-Dist: packaging==24.2\\nRequires-Dist: colorama==0.4.6; sys_platform == "win32"\\n',
        info + 'WHEEL': b'Wheel-Version: 1.0\\nGenerator: bundlr-acceptance\\nRoot-Is-Purelib: PURELIB\\nTag: py3-none-any\\n',
        info + 'entry_points.txt': b'[console_scripts]\\ngit-demo = application:main\\n[gui_scripts]\\ngit-window = application:window\\n',
        info + 'LICENSE': b'Bundlr synthetic acceptance fixture.\\n',
    }
    record = []
    for path, data in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
        record.append(path + ',sha256=' + digest + ',' + str(len(data)))
    files[info + 'RECORD'] = ('\\n'.join(record) + '\\n' + info + 'RECORD,,\\n').encode()
    with zipfile.ZipFile(Path(wheel_directory) / name, 'w') as archive:
        for path, data in files.items():
            item = zipfile.ZipInfo(path)
            item.create_system = 3
            item.external_attr = (0o100755 if path == 'packaged-helper' else 0o100644) << 16
            archive.writestr(item, data)
    return name
""";
    write_text(
        join_path(directory, "backend.py"),
        backend.replace("PURELIB", "true" if portable else "false").replace(
            "24.2", PACKAGING_VERSION
        ).replace(
            "0.4.6", COLORAMA_VERSION
        )
    );
    run(["git", "init", "--initial-branch=main", str(directory)]);
    run(
        [
            "git",
            "-C",
            str(directory),
            "add",
            "pyproject.toml",
            "application.py",
            "backend.py"
        ]
    );
    run(
        [
            "git",
            "-C",
            str(directory),
            "-c",
            "user.name=Bundlr acceptance",
            "-c",
            "user.email=acceptance@example.invalid",
            "commit",
            "-m",
            "Pinned acceptance fixture"
        ]
    );
    revision = run(["git", "-C", directory, "rev-parse", "HEAD"]).strip();
    assert len(revision) == 40;
    environment: dict[str, str] = {};
    # Keep the public source contract HTTPS and exercise the real Git/PEP 517
    # path without depending on a mutable third-party project or remote server.
    environment["GIT_CONFIG_COUNT"] = "1";
    uri = ("file:///" if sys.platform == "win32" else "file://")
        + directory.replace(" ", "%20");
    environment["GIT_CONFIG_KEY_0"] = "url." + uri + ".insteadOf";
    environment["GIT_CONFIG_VALUE_0"] = GIT_SOURCE;
    environment["GIT_TERMINAL_PROMPT"] = "0";
    return (GIT_SOURCE + "@" + revision, environment);
}

def unpack(path: str, directory: str) -> Extractor {
    reader = Extractor(source=path, destination=directory, strip_root=False);
    try {
        reader.start();
        while not reader.done {
            reader.advance();
        }
    } finally {
        reader.close();
    }
    return reader;
}

def launcher(directory: str, name: str, target: str) -> str {
    if target.startswith("macos-") {
        return join_path(
            directory, name + "-" + target + ".app/Contents/MacOS/" + name
        );
    }
    return join_path(
        directory,
        name
            + "-"
            + target
            + "/"
            + name
            + (".exe" if target == "windows-x86_64" else "")
    );
}

def artifact_path(directory: str, name: str, target: str) -> str {
    return join_path(
        directory, name + "-" + target + (".app" if target.startswith("macos-") else "")
    );
}

def verify_archive(path: str, directory: str, name: str, target: str) {
    digest = file_sha256(path);
    assert read_text(path + ".sha256").strip()
        == digest + "  " + path.replace("\\", "/").split("/")[-1];
    reader = unpack(path, directory);
    if target == "windows-x86_64" {
        return;
    }
    metadata = reader.metadata;
    application = launcher(directory, name, target);
    assert metadata.modes[application] & 64;
    runtime = join_path(
        artifact_path(directory, name, target),
        "Contents/Resources/runtime" if target.startswith("macos-") else "runtime"
    );
    executable = join_path(runtime, "bin/python3");
    visited: list[str] = [];
    while executable in metadata.symlinks {
        assert executable not in visited;
        visited.append(executable);
        executable = join_path(parent_path(executable), metadata.symlinks[executable]);
    }
    assert metadata.modes[executable] & 64;
    for member_path in metadata.modes {
        if stat_path(member_path).is_dir() {
            assert metadata.modes[member_path] & 64;
        }
    }
}

def verify_evidence(directory: str, target: str, source: str = "") {
    resources = join_path(directory, "Contents/Resources")
        if target.startswith("macos-")
        else directory;
    manifest = json.loads(read_text(join_path(resources, "bundlr-manifest.json")));
    assert manifest["target"] == target;
    if source != "" {
        assert manifest["source"] == source;
    }
    for line in read_text(join_path(resources, "SHA256SUMS")).splitlines() {
        parts = line.split("  ", 1);
        assert file_sha256(join_path(resources, parts[1])) == parts[0];
    }
    assert stat_path(join_path(resources, "THIRD_PARTY_LICENSES.txt")).is_file();
    if source != "" {
        inventory = json.loads(
            read_text(join_path(resources, "bundlr-dependencies.json"))
        );
        versions: dict[str, str] = {};
        for item in inventory["dependencies"] {
            versions[str(item["name"]).lower()] = str(item["version"]);
        }
        assert versions["packaging"] == PACKAGING_VERSION;
        assert ("colorama" in versions) == (target == "windows-x86_64");
    }
}

def recipient_environment -> dict[str, str] {
    environment = {
        "PYTHONHOME": "bundlr-must-ignore-builder-python",
        "PYTHONPATH": "bundlr-must-ignore-builder-packages"
    };
    if sys.platform == "win32" {
        system_root = os.getenv("SystemRoot");
        assert system_root is not None;
        environment["PATH"] = join_path(system_root, "System32");
    }
    return environment;
}

def recipient_arguments(name: str) -> list[str] {
    return ["--version"]
        if name == "Black"
        else ["literal spaces; $(safe)", "quoted \"value\""];
}

def consume(directory: str, output: str, target: str) {
    for name in ["Black", "GitDemo"] {
        archive = join_path(directory, name + "-" + target + ".tar.gz");
        inspected = join_path(output, "inspected-" + name);
        verify_archive(archive, inspected, name, target);
        extracted = join_path(output, "recipient-" + name);
        make_dirs(extracted);
        # Use the recipient OS's tar, independently of Bundlr's extractor.
        run(["tar", "-xzf", archive, "-C", extracted]);
        verify_evidence(artifact_path(extracted, name, target), target);
        result = run(
            [launcher(extracted, name, target)] + recipient_arguments(name),
            recipient_environment()
        );
        assert (
            "black, " + BLACK_VERSION if name == "Black" else "Bundlr Git acceptance:"
        )
            in result , result;
    }
    print("Cross-built Black and Git archives launched on " + target + ".");
}

def accept(binary: str, output: str, all_targets: bool) {
    target = current_target();
    environment = {"BUNDLR_CACHE_DIRECTORY": join_path(output, "cache")};
    run([binary, "--diagnose"], environment);
    (source, git_environment) = git_fixture(join_path(output, "git-portable"), True);
    git_environment["BUNDLR_CACHE_DIRECTORY"] = environment["BUNDLR_CACHE_DIRECTORY"];
    targets = TARGETS if all_targets else [target];
    for selected in targets {
        for (name, command, requirement, env) in [
            ("Black", "black", "black==" + BLACK_VERSION, environment),
            ("GitDemo", "git-demo", source, git_environment)
        ] {
            run(
                [
                    binary,
                    "--name",
                    name,
                    "--command",
                    command,
                    "--target",
                    selected,
                    "--output",
                    output,
                    requirement
                ],
                env
            );
            extension = ".zip" if selected == "windows-x86_64" else ".tar.gz";
            archive = join_path(output, name + "-" + selected + extension);
            extracted = join_path(output, "extracted-" + name + "-" + selected);
            verify_archive(archive, extracted, name, selected);
            verify_evidence(
                artifact_path(extracted, name, selected),
                selected,
                source if name == "GitDemo" else ""
            );
            if selected == target {
                result = run(
                    [launcher(extracted, name, selected)] + recipient_arguments(name),
                    recipient_environment()
                );
                assert (
                    "black, " + BLACK_VERSION
                        if name == "Black"
                        else "Bundlr Git acceptance:"
                )
                    in result , result;
            }
        }
    }
    (invalid_source, invalid_environment) = git_fixture(
        join_path(output, "git-nonportable"), False
    );
    invalid_environment["BUNDLR_CACHE_DIRECTORY"] = environment[
        "BUNDLR_CACHE_DIRECTORY"
    ];
    rejected = join_path(output, "rejected");
    result = run(
        [
            binary,
            "--name",
            "Rejected",
            "--command",
            "git-demo",
            "--target",
            target,
            "--output",
            rejected,
            invalid_source
        ],
        invalid_environment,
        False
    );
    assert "pure" in result.lower() or "portable" in result.lower();
    assert len(list_dir(rejected)) == 0;
    if target == "windows-x86_64" {
        run(
            [
                binary,
                "--name",
                "GitWindow",
                "--command",
                "git-window",
                "--kind",
                "windowed",
                "--target",
                target,
                "--output",
                output,
                source
            ],
            git_environment
        );
        extracted = join_path(output, "extracted-gui");
        verify_archive(
            join_path(output, "GitWindow-windows-x86_64.zip"),
            extracted,
            "GitWindow",
            target
        );
        marker = join_path(output, "gui-success.txt");
        gui_environment = recipient_environment();
        gui_environment["BUNDLR_GUI_MARKER"] = marker;
        run([launcher(extracted, "GitWindow", target)], gui_environment);
        assert read_text(marker) == "tkinter event loop passed";
        print(
            "Windowed pythonw.exe launcher and real Tk event loop passed without builder tools on PATH."
        );
    }
    print("Production builder acceptance passed: " + target);
}

with entry {
    try {
        args = sys.argv[1:];
        if len(args) != 3 {
            raise ValueError(
                "Usage: acceptance-test <builder|all|consume|fixtures> <bundlr-or-archives> <new-output>"
            );
        }
        output = absolute_path(args[2]);
        assert not stat_path(output).exists;
        make_dirs(output);
        if args[0] == "consume" {
            consume(absolute_path(args[1]), output, current_target());
        } elif args[0] == "fixtures" {
            (source, environment) = git_fixture(join_path(output, "fixture"), True);
            clone = join_path(output, "clone");
            run(["git", "clone", GIT_SOURCE, clone], environment);
            revision = run(["git", "-C", clone, "rev-parse", "HEAD"]).strip();
            assert source.endswith("@" + revision);
            print("Pinned HTTPS Git fixture rewrite and clone passed.");
        } else {
            assert args[0] in ["builder", "all"];
            accept(absolute_path(args[1]), output, args[0] == "all");
        }
    } except Exception as error {
        sys.stderr.write(str(error) + "\n");
        sys.`exit(1);
    }
}
