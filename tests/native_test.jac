"""Compile natively to exercise the same code and C ABI as the release."""
import sys;
import time;
import from tests.domain_test {
    check_pins,
    check_rejections,
    check_git,
    check_cli,
    check_invalid_requests
}
import from tests.http_contract { check_http }
import from src.domain.request { parse_cli, TARGETS, decode_request }
import from src.core.build_job { BuildJob, BuildEvents, binary_install_args }
import from src.core.distribution {
    distribution,
    PythonDistribution,
    runtime_cache_name
}
import from src.core.metadata {
    parse_entry_point,
    application_entries,
    portable_git_wheel,
    wheel_requirements,
    installed_entry_point,
    EvidenceTask,
    HashTask
}
import from src.core.launchers { resources_path, launcher_zip, create_launcher }
import from src.platform.files {
    temp_dir,
    write_text,
    read_text,
    write_bytes,
    read_bytes,
    file_sha256,
    stat_path,
    list_dir,
    remove_tree,
    make_dirs,
    join_path,
    parent_path,
    native_path,
    symlink_file,
    chmod_file
}
import from src.platform.processes { start_child, Child }
import from src.platform.ffi_uv { uv_run, uv_default_loop, uv_kill }
import from src.platform.archives {
    ArchiveWriter,
    Extractor,
    archive_name,
    check_zip_limits,
    ArchiveMetadata,
    PathCursor,
    tree_entries
}

obj QuietEvents(BuildEvents) {
    has errors: str = "",
        output: str = "";

    override def stdout(text: str) {
        self.output += text;
    }

    override def stderr(text: str) {
        self.errors += text;
    }

    override def finished(results: list[dict[str, str]]) {
        _ = results;
    }
}

def pump(child: Child) {
    deadline = time.monotonic() + 10.0;
    while not child.done() {
        assert time.monotonic() < deadline;
        uv_run(uv_default_loop(), 2);
        time.sleep(0.001);
    }
}

def check_processes(fixture: str) {
    events = QuietEvents();
    child = start_child(
        fixture, ["argument", "literal spaces; $(safe)"], events, capture=True
    );
    pump(child);
    assert child.code == 0;
    assert child.output == "literal spaces; $(safe)";
    events = QuietEvents();
    child = start_child(fixture, ["stream"], events, capture=True);
    pump(child);
    assert child.code == 0;
    assert child.output == "out\n" * 32 , "Captured stdout: " + repr(child.output);
    assert events.errors == "err\n" * 32 , "Captured stderr: " + repr(events.errors);
    # Check raw LF, CRLF and lone CR through both direct and relayed pipes.
    # Windows start_child also inserts the production Job Object child runner.
    for mode in ["newlines", "relay"] {
        for contained in [False, True] {
            events = QuietEvents();
            child = start_child(
                fixture, [mode], events, capture=True, contain_tree=contained
            );
            pump(child);
            assert child.code == 0;
            assert child.output == "out\ncrlf\r\ncr\rend" , "Captured stdout: "
                + repr(child.output);
            assert events.errors == "err\ncrlf\r\ncr\rend" , "Captured stderr: "
                + repr(events.errors);
        }
    }
    child = start_child(
        fixture, ["environment"], events, {"BUNDLR_TEST_VALUE": "spaces = intact"}, True
    );
    pump(child);
    assert child.output == "spaces = intact";
    child = start_child(fixture, ["fail"], events);
    pump(child);
    assert child.code == 7;
    child = start_child(fixture, ["sleep"], events);
    child.cancel();
    child.cancel();
    pump(child);
    assert child.code != 0;
    child = start_child(fixture, ["tree"], QuietEvents(), capture=True);
    deadline = time.monotonic() + 10.0;
    while "\n" not in child.output {
        assert time.monotonic() < deadline;
        uv_run(uv_default_loop(), 2);
        time.sleep(0.001);
    }
    descendant = int(child.output.strip());
    try {
        child.cancel();
        pump(child);
        assert child.code != 0;
        if sys.platform == "win32" {
            assert uv_kill(i32(descendant), 0) < 0;
        }
    } finally {
        uv_kill(i32(descendant), 9);
    }
    caught = False;
    try {
        start_child(fixture + "-absent", [], events);
    } except RuntimeError {
        caught = True;
    }
    assert caught;
    uv_run(uv_default_loop(), 2);
}

def check_metadata {
    point = parse_entry_point("demo", "console", "demo.cli:App.main [colour]");
    assert point.module == "demo.cli";
    assert point.attributes == ["App", "main"];
    for value in ["demo", "demo:main()", "demo:main;evil", "demo:main:extra"] {
        caught = False;
        try {
            parse_entry_point("demo", "console", value);
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
    points = application_entries(
        "[console_scripts]\ndemo = demo:main\n[gui_scripts]\nwindow = demo:window\n", ""
    );
    assert len(points) == 2;
    assert points[1].kind == "windowed";
    portable_git_wheel("Root-Is-Purelib: true\nTag: py3-none-any\nTag: py2-none-any\n");
    for wheel in [
        "Root-Is-Purelib: false\nTag: py3-none-any",
        "Root-Is-Purelib: true\nTag: cp312-cp312-linux_x86_64",
        "Root-Is-Purelib: true"
    ] {
        caught = False;
        try {
            portable_git_wheel(wheel);
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
    assert wheel_requirements(
        "Name: demo\nRequires-Dist: click>=8\nRequires-Dist: colour;\n  sys_platform == 'win32'\n\nDescription"
    )
        == ["click>=8", "colour;sys_platform == 'win32'"];
    for target in TARGETS {
        args = binary_install_args(["demo==1"], target, "packages with spaces");
        assert "--only-binary" in args;
        assert ":all:" in args;
        assert distribution(target).triple in args;
        assert args[-1] == "demo==1";
        assert len(distribution(target).sha256) == 64;
    }
    assert decode_request(
        '{"source":"demo==1","targets":["linux-x86_64"]}'
    ).applicationName
        == "demo";
    # Regression: gstack API review, 2026-11-04: malformed kind must not become auto.
    for body in [
        "[]",
        "null",
        "{}",
        '{"source":"demo==1","targets":[42]}',
        '{"source":"demo==1","targets":["linux-x86_64"],"applicationKind":42}',
        '{"source":"demo==1","targets":["linux-x86_64"],"applicationKind":""}'
    ] {
        caught = False;
        try {
            decode_request(body);
        } except Exception {
            caught = True;
        }
        assert caught;
    }
}

def check_directory_links(base: str) {
    if sys.platform == "win32" {
        return;
    }
    directory = join_path(base, "real-output");
    link = join_path(base, "linked-output");
    make_dirs(directory);
    symlink_file("real-output", link);
    make_dirs(link);
    make_dirs(join_path(link, "nested"));
    assert stat_path(join_path(directory, "nested")).is_dir();
    assert stat_path(link).is_link();
    remove_tree(link);
    assert stat_path(directory).is_dir();
}

def check_windows_launchers(base: str) {
    for kind in ["console", "windowed"] {
        artifact = join_path(base, "launcher-" + kind);
        stub_directory = join_path(
            artifact, "runtime/Lib/site-packages/pip/_vendor/distlib"
        );
        make_dirs(stub_directory);
        stub_name = "w64.exe" if kind == "windowed" else "t64.exe";
        python_name = "pythonw.exe" if kind == "windowed" else "python.exe";
        stub = b"MZ-windowed" if kind == "windowed" else b"MZ-console";
        write_bytes(join_path(stub_directory, stub_name), stub);
        request = parse_cli(
            [
                "--name",
                "Example",
                "--kind",
                kind,
                "--target",
                "windows-x86_64",
                "demo==1"
            ]
        );
        create_launcher(
            request,
            artifact,
            "windows-x86_64",
            parse_entry_point("demo", kind, "demo:main")
        );
        data = read_bytes(join_path(artifact, "Example.exe"));
        shebang = ("#!<launcher_dir>\\runtime\\" + python_name + " -I -B\n").encode(
            "utf-8"
        );
        assert data[:len(stub)] == stub;
        assert data[len(stub):len(stub) + len(shebang)] == shebang;
        zip_path = join_path(artifact, "launcher.zip");
        write_bytes(zip_path, data[len(stub) + len(shebang):]);
        extract(zip_path, zip_path + "-out", False);
        main = read_text(join_path(zip_path + "-out", "__main__.py"));
        assert "site.addsitedir(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), 'packages'))"
            in main;
        assert "raise SystemExit(_bundlr_module.main())" in main;
    }
}

def check_default_entry_point(base: str) {
    packages = join_path(base, "entry-selection");
    metadata = join_path(packages, "black-26.10.1.dist-info");
    make_dirs(metadata);
    write_text(join_path(metadata, "METADATA"), "Name: black\nVersion: 26.10.1\n");
    write_text(
        join_path(metadata, "entry_points.txt"),
        "[console_scripts]\nblack = black:patched_main\nblackd = blackd:patched_main\n"
    );
    # Regression: Black exposes two commands; its package-named command is the default.
    assert installed_entry_point(packages, "").command == "black";
    assert installed_entry_point(packages, "blackd", "black").command == "blackd";
    caught = False;
    try {
        installed_entry_point(packages, "missing", "black");
    } except ValueError {
        caught = True;
    }
    assert caught;

    dependency = join_path(packages, "helper-1.dist-info");
    make_dirs(dependency);
    write_text(join_path(dependency, "METADATA"), "Name: helper\nVersion: 1\n");
    write_text(
        join_path(dependency, "entry_points.txt"),
        "[console_scripts]\nhelper = helper:main\n"
    );
    assert installed_entry_point(packages, "", "Black").command == "black";
    # Exercise the real post-install phase used by both CLI and browser, including
    # the source-name hint so dependency commands cannot make Black ambiguous.
    request = parse_cli(
        ["--name", "Formatter", "--target", "linux-x86_64", "black==26.10.1"]
    );
    job = BuildJob(
        request=request,
        events=QuietEvents(),
        packages=packages,
        phase="install",
        child=Child(
            events=QuietEvents(), exited=True, stdout_eof=True, stderr_eof=True, code=0
        )
    );
    job.advance();
    assert job.error == "";
    assert job.phase == "launchers";
    point = job.point;
    assert point is not None;
    assert point.command == "black";

    write_text(join_path(metadata, "METADATA"), "Name: My_App\nVersion: 1\n", False);
    write_text(
        join_path(metadata, "entry_points.txt"),
        "[console_scripts]\nmy-app = main:run\nserver = main:serve\n",
        False
    );
    assert installed_entry_point(packages, "", "my.app").command == "my-app";
    # A matching command in a dependency must not resolve ambiguity in the root.
    write_text(
        join_path(metadata, "entry_points.txt"),
        "[console_scripts]\nformat = main:run\nserver = main:serve\n",
        False
    );
    caught = False;
    try {
        installed_entry_point(packages, "", "my_app");
    } except ValueError {
        caught = True;
    }
    assert caught;
    assert installed_entry_point(packages, "server", "my_app").command == "server";
    write_text(
        join_path(metadata, "entry_points.txt"),
        "[console_scripts]\nmy-app = main:run\nmy_app = main:other\n",
        False
    );
    caught = False;
    try {
        installed_entry_point(packages, "", "my_app");
    } except ValueError {
        caught = True;
    }
    assert caught;
}

def extract(source: str, destination: str, strip: bool = True) {
    reader = Extractor(source=source, destination=destination, strip_root=strip);
    try {
        reader.start();
        while not reader.done {
            reader.advance();
        }
    } finally {
        reader.close();
    }
}

def check_path_cursor(base: str) {
    directory = join_path(base, "cursor");
    nested = join_path(directory, "a");
    empty = join_path(nested, "empty");
    file = join_path(nested, "file.txt");
    last = join_path(directory, "z.txt");
    make_dirs(empty);
    write_text(file, "nested");
    write_text(last, "last");
    expected = [directory, nested, empty, file];
    if sys.platform != "win32" {
        link = join_path(directory, "link");
        symlink_file("a", link);
        expected.append(link);
    }
    expected.append(last);
    assert list(tree_entries(directory)) == expected;
    virtual = join_path(directory, "virtual");
    cursor = PathCursor(pending=[directory], deferred=[virtual, last]);
    actual: list[str] = [];
    while True {
        path = cursor.advance();
        if path == "" {
            break;
        }
        actual.append(path);
    }
    assert actual == expected + [virtual];
    assert cursor.advance() == "";
}

def check_archives(base: str) {
    source = join_path(base, "archive source");
    make_dirs(source);
    write_text(join_path(source, "data.txt"), "abc");
    make_dirs(join_path(source, "empty"));
    assert file_sha256(join_path(source, "data.txt"))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    for zipped in [False, True] {
        archive = source + (".zip" if zipped else ".tar.gz");
        writer = ArchiveWriter(source=source, destination=archive, windows_zip=zipped);
        try {
            writer.start();
            while not writer.done {
                writer.advance();
            }
        } finally {
            writer.close();
        }
        destination = archive + "-extracted";
        extract(archive, destination);
        assert read_text(join_path(destination, "data.txt")) == "abc";
        assert stat_path(join_path(destination, "empty")).is_dir();
        if zipped {
            assert b"PK\x06\x06" not in read_bytes(archive);
        }
    }
    for path in ["../escape", "/absolute", "C:\\escape", "a/../../b"] {
        caught = False;
        try {
            archive_name(path);
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
    for limits in [(4294967295, 1), (1, 65536)] {
        caught = False;
        try {
            check_zip_limits(limits[0], limits[1]);
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
    zip_path = join_path(base, "launcher.zip");
    write_bytes(zip_path, launcher_zip("print('launcher')\n"));
    extract(zip_path, zip_path + "-out", False);
    assert read_text(join_path(zip_path + "-out", "__main__.py"))
        == "print('launcher')\n";
}

def check_archive_metadata(base: str) {
    source = join_path(base, "unix-metadata");
    make_dirs(source);
    executable = join_path(source, "python3");
    write_text(executable, "#!/bin/sh\nexit 0\n");
    metadata = ArchiveMetadata();
    metadata.modes[source] = 488;
    metadata.modes[executable] = 489;
    packages = join_path(source, "packages/fixture");
    make_dirs(packages);
    helper = join_path(packages, "helper");
    write_text(helper, "#!/bin/sh\nexit 0\n");
    metadata.executable_roots = [join_path(source, "packages")];
    metadata.modes[join_path(source, "python")] = 511;
    metadata.symlinks[join_path(source, "python")] = "python3";
    archive = source + ".tar.gz";
    writer = ArchiveWriter(
        source=source, destination=archive, windows_zip=False, metadata=metadata
    );
    writer.start();
    while not writer.done {
        writer.advance();
    }
    destination = source + "-windows-staging";
    reader = Extractor(
        source=archive, destination=destination, materialize_symlinks=False
    );
    reader.start();
    while not reader.done {
        reader.advance();
    }
    assert not stat_path(join_path(destination, "python")).exists;
    assert reader.metadata.modes[join_path(destination, "python3")] == 489;
    assert reader.metadata.modes[join_path(destination, "packages/fixture/helper")]
        & 73;
    chmod_file(join_path(destination, "python3"), 420);
    repacked = source + "-repacked.tar.gz";
    writer = ArchiveWriter(
        source=destination,
        destination=repacked,
        windows_zip=False,
        metadata=reader.metadata
    );
    writer.start();
    while not writer.done {
        writer.advance();
    }
    restored = source + "-restored";
    final_reader = Extractor(source=repacked, destination=restored);
    final_reader.start();
    while not final_reader.done {
        final_reader.advance();
    }
    assert final_reader.metadata.modes[join_path(restored, "python3")] == 489;
    assert final_reader.metadata.modes[restored] == 488;
    assert final_reader.metadata.symlinks[join_path(restored, "python")] == "python3";
    assert final_reader.metadata.modes[join_path(restored, "packages/fixture/helper")]
        & 73;
    if sys.platform != "win32" {
        assert (stat_path(join_path(restored, "python3")).mode & 511) == 489;
        assert stat_path(join_path(restored, "python")).is_link();
    }
}

def check_archive_case_collisions(base: str) {
    source = join_path(base, "case-source");
    make_dirs(source);
    metadata = ArchiveMetadata();
    entries = [
        ("a-upper", "share/terminfo/e/Eterm", "upper payload"),
        ("b-lower", "share/terminfo/e/eterm", "different lower payload"),
        ("directory-upper/item", "Lib/item", "upper directory"),
        ("directory-lower/item", "lib/item", "lower directory"),
        ("zzz-reserved", "share/terminfo/e/_bundlr_case_0", "original reserved name")
    ];
    for (stored, original, content) in entries {
        path = join_path(source, stored);
        make_dirs(parent_path(path));
        write_text(path, content);
        metadata.original_paths[path] = join_path(source, original);
        metadata.modes[path] = 489;
    }
    metadata.original_paths[join_path(source, "directory-upper")] = join_path(
        source, "Lib"
    );
    metadata.original_paths[join_path(source, "directory-lower")] = join_path(
        source, "lib"
    );
    links = [
        ("virtual-link", "share/terminfo/e/ETERM", "Eterm", "upper payload"),
        (
            "lower-link",
            "lower-alias",
            "share/terminfo/e/eterm",
            "different lower payload"
        ),
        ("parent-link", "lib/alias", "item", "lower directory"),
        (
            "upward-link",
            "lib/upward",
            "../share/terminfo/e/eterm",
            "different lower payload"
        ),
        ("self-link", "lib/self", ".", "lower directory"),
        ("directory-link", "directory-alias", "lib", "lower directory")
    ];
    for (stored, original, target, _) in links {
        link = join_path(source, stored);
        metadata.original_paths[link] = join_path(source, original);
        metadata.symlinks[link] = target;
        metadata.modes[link] = 511;
    }
    archive = source + ".tar.gz";
    writer = ArchiveWriter(
        source=source, destination=archive, windows_zip=False, metadata=metadata
    );
    writer.start();
    while not writer.done {
        writer.advance();
    }
    destination = source + "-staged";
    # Exercise case-insensitive staging with virtual links on every host.
    reader = Extractor(
        source=archive,
        destination=destination,
        case_sensitive=False,
        materialize_symlinks=False
    );
    reader.start();
    while not reader.done {
        reader.advance();
    }
    for (_, original, content) in entries {
        path = reader.metadata.stored_path(join_path(destination, original));
        assert read_text(path) == content;
        assert reader.metadata.modes[path] == 489;
    }
    assert len(reader.metadata.original_paths) > 0;
    evidence = EvidenceTask(directory=destination, metadata=reader.metadata);
    evidence.start();
    while not evidence.done {
        evidence.advance();
    }
    sums = read_text(join_path(destination, "SHA256SUMS"));
    assert len(sums.splitlines()) == len(entries);
    for (_, original, _) in entries {
        path = reader.metadata.stored_path(join_path(destination, original));
        assert file_sha256(path) + "  " + original + "\n" in sums;
    }
    repacked = source + "-repacked.tar.gz";
    writer = ArchiveWriter(
        source=destination,
        destination=repacked,
        windows_zip=False,
        metadata=reader.metadata
    );
    writer.start();
    while not writer.done {
        writer.advance();
    }
    # Restore using volume detection, then force aliases even on Linux so Unix
    # symlinks to aliased files and directories are covered on every Unix host.
    for case_sensitive in [None, False] {
        restored = source + ("-restored" if case_sensitive is None else "-aliased");
        final_reader = Extractor(
            source=repacked, destination=restored, case_sensitive=case_sensitive
        );
        final_reader.start();
        assert final_reader.case_sensitive is not None;
        assert list_dir(restored) == [];
        while not final_reader.done {
            final_reader.advance();
        }
        if case_sensitive is None {
            assert final_reader.case_sensitive
                == (not stat_path(join_path(restored, "sha256sums")).exists);
        }
        for (_, original, content) in entries {
            path = final_reader.metadata.stored_path(join_path(restored, original));
            assert read_text(path) == content;
            assert final_reader.metadata.modes[path] == 489;
        }
        for (_, original, target, content) in links {
            path = final_reader.metadata.stored_path(join_path(restored, original));
            assert final_reader.metadata.symlinks[path] == target;
            if sys.platform != "win32" {
                assert stat_path(path).is_link();
                if stat_path(path, True).is_dir() {
                    path = join_path(path, "item");
                }
                assert read_text(path) == content;
            }
        }
        assert read_text(join_path(restored, "SHA256SUMS")) == sums;
    }
    # Genuine duplicate members must still fail rather than overwrite data.
    metadata.original_paths[join_path(source, "b-lower")] = join_path(
        source, "share/terminfo/e/Eterm"
    );
    duplicate = source + "-duplicate.tar.gz";
    writer = ArchiveWriter(
        source=source, destination=duplicate, windows_zip=False, metadata=metadata
    );
    writer.start();
    while not writer.done {
        writer.advance();
    }
    reader = Extractor(
        source=duplicate, destination=source + "-duplicate", case_sensitive=False
    );
    rejected = False;
    try {
        reader.start();
        while not reader.done {
            reader.advance();
        }
    } except RuntimeError {
        rejected = True;
    } finally {
        reader.close();
    }
    assert rejected;
    assert read_text(join_path(source + "-duplicate", "share/terminfo/e/Eterm"))
        == "upper payload";
}

def seed_job(base: str, target: str) -> BuildJob {
    request = parse_cli(["--target", target, "--output", base, "demo==1"]);
    job = BuildJob(request=request, events=QuietEvents());
    job.start();
    job.target = target;
    job.artifact_name = "demo-"
        + target
        + (".app" if target.startswith("macos-") else "");
    job.artifact_path = join_path(base, job.artifact_name);
    job.archive_path = join_path(
        base, "demo-" + target + (".zip" if target == "windows-x86_64" else ".tar.gz")
    );
    job.staging = temp_dir(base, ".bundlr-build-");
    job.resources = resources_path(join_path(job.staging, job.artifact_name), target);
    job.packages = join_path(job.resources, "packages");
    metadata = join_path(job.packages, "demo-1.dist-info");
    make_dirs(metadata);
    write_text(join_path(metadata, "METADATA"), "Name: demo\nVersion: 1\n");
    write_text(
        join_path(metadata, "entry_points.txt"), "[console_scripts]\ndemo = demo:main\n"
    );
    write_text(join_path(metadata, "LICENSE"), "Test licence\n");
    write_text(
        join_path(job.packages, "demo.py"), "def main():\n    print('packaged app')\n"
    );
    make_dirs(join_path(job.resources, "runtime"));
    write_text(
        join_path(job.resources, "runtime/LICENSE.txt"), "Python test fixture\n"
    );
    if target == "windows-x86_64" {
        stub = join_path(
            job.resources, "runtime/Lib/site-packages/pip/_vendor/distlib"
        );
        make_dirs(stub);
        write_bytes(join_path(stub, "t64.exe"), b"MZtest-stub");
    }
    job.point = installed_entry_point(job.packages, "");
    job.phase = "launchers";
    return job;
}

def runtime_job(base: str, cache: str, digest: str) -> BuildJob {
    staging = temp_dir(base, "runtime-job-");
    return BuildJob(
        request=parse_cli(["--target", "linux-x86_64", "demo==1"]),
        events=QuietEvents(),
        staging=staging,
        resources=join_path(staging, "resources"),
        runtime_cache_path=cache,
        python_distribution=PythonDistribution(
            target="linux-x86_64", triple="fixture", sha256=digest, executable="python3"
        )
    );
}

def check_runtime_cache(base: str) {
    source = join_path(base, "runtime-fixture");
    make_dirs(source);
    write_text(join_path(source, "python3"), "verified runtime fixture");
    archive = source + ".tar.gz";
    writer = ArchiveWriter(source=source, destination=archive, windows_zip=False);
    writer.start();
    while not writer.done {
        writer.advance();
    }
    payload = read_bytes(archive);
    digest = file_sha256(archive);
    identities = [
        "https://example.invalid/cpython-3.12.13+1-linux.tar.gz",
        "https://example.invalid/cpython-3.12.14+1-linux.tar.gz",
        "https://example.invalid/cpython-3.12.13+2-linux.tar.gz",
        "https://example.invalid/cpython-3.12.13+1-windows.tar.gz"
    ];
    names = [runtime_cache_name(url, digest) for url in identities];
    assert len(set(names)) == len(identities);
    assert runtime_cache_name(identities[0], "0" * 64) != names[0];
    assert runtime_cache_name(identities[0], digest) == names[0];
    cache = join_path(base, "python-cache/" + digest + ".tar.gz");
    # Repair an archive whose checksum failed, then publish a second verified
    # download while the first extractor still holds the shared cache open.
    make_dirs(parent_path(cache));
    for invalid in [False, True] {
        if invalid {
            write_text(cache, "corrupt cached runtime", False);
        }
        readers: list[BuildJob] = [];
        for i in range(2) {
            job = runtime_job(base, cache, digest);
            job.runtime_cache_invalid = invalid and i == 0;
            job.runtime_staging = temp_dir(parent_path(cache), ".python-");
            partial = job.runtime_staging;
            job.runtime_archive = join_path(partial, "python.tar.gz");
            write_bytes(job.runtime_archive, payload);
            job.hashing = HashTask(path=job.runtime_archive);
            job.hashing.start();
            job.phase = "verify";
            finish(job, "extract");
            assert job.error == "";
            assert file_sha256(cache) == digest;
            assert stat_path(partial).exists == (i == 1);
            assert (job.runtime_archive == cache) == (i == 0);
            readers.append(job);
        }
        for job in readers {
            reader = job.extractor;
            assert reader is not None;
            while not reader.done {
                reader.advance();
            }
            assert read_text(join_path(job.resources, "runtime/python3"))
                == "verified runtime fixture";
            partial = job.runtime_staging;
            job.cleanup();
            if partial != "" {
                assert not stat_path(partial).exists;
            }
        }
    }
    # A warm cache is still hashed before an extractor can use it.
    job = runtime_job(base, cache, digest);
    job.prepare_runtime();
    assert job.phase == "verify";
    assert job.download is None;
    finish(job, "extract");
    assert job.error == "";
    reader = job.extractor;
    assert reader is not None;
    while not reader.done {
        reader.advance();
    }
    assert read_text(join_path(job.resources, "runtime/python3"))
        == "verified runtime fixture";
    job.cleanup();
    # Cache misses and corrupt hits fall back to a private download. Cancellation
    # removes it without publishing an archive or touching the existing cache.
    for corrupt in [False, True] {
        path = cache
            if corrupt
            else join_path(base, "empty-cache/" + digest + ".tar.gz");
        if corrupt {
            write_text(path, "corrupt cached runtime", False);
        }
        job = runtime_job(base, path, digest);
        job.prepare_runtime();
        if corrupt {
            finish(job, "download");
        }
        assert job.phase == "download";
        partial = job.runtime_staging;
        assert stat_path(partial).is_dir();
        assert job.runtime_archive != path;
        job.cancel();
        job.advance();
        assert job.error == "Build cancelled.";
        assert not stat_path(partial).exists;
        assert stat_path(path).exists == corrupt;
    }
    # Downloaded bytes with a bad checksum must never replace a cache entry.
    job = runtime_job(base, cache, digest);
    job.runtime_staging = temp_dir(parent_path(cache), ".python-");
    partial = job.runtime_staging;
    job.runtime_archive = join_path(partial, "python.tar.gz");
    write_text(job.runtime_archive, "bad download");
    job.hashing = HashTask(path=job.runtime_archive);
    job.hashing.start();
    job.phase = "verify";
    finish(job);
    assert job.error == "Python runtime failed SHA-256 verification.";
    assert read_text(cache) == "corrupt cached runtime";
    assert not stat_path(partial).exists;
}

def finish(job: BuildJob, stop: str = "") {
    for i in range(10000) {
        if job.done or (stop != "" and job.phase == stop) {
            return;
        }
        job.advance();
    }
    raise RuntimeError("Build fixture did not complete.");
}

def check_builds(base: str) {
    for target in TARGETS {
        directory = join_path(base, target);
        job = seed_job(directory, target);
        finish(job);
        assert job.error == "";
        assert len(job.results) == 1;
        assert file_sha256(job.archive_path) == job.archive_digest;
        assert read_text(job.archive_path + ".sha256").startswith(
            job.archive_digest + "  "
        );
        resources = resources_path(job.artifact_path, target);
        assert '"formatVersion": 1'
            in read_text(join_path(resources, "bundlr-manifest.json"));
        assert "demo-1.dist-info/METADATA"
            in read_text(join_path(resources, "SHA256SUMS"));
        assert "Test licence"
            in read_text(join_path(resources, "THIRD_PARTY_LICENSES.txt"));
        assert '"name": "demo"'
            in read_text(join_path(resources, "bundlr-dependencies.json"));
        assert len(list_dir(directory)) == 3;
        caught = False;
        try {
            BuildJob(request=job.request, events=QuietEvents()).start();
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
    for collision in ["directory", "archive", "checksum"] {
        directory = join_path(base, "race-" + collision);
        job = seed_job(directory, "linux-x86_64");
        finish(job, "publish");
        retained = job.archive_path;
        if collision == "directory" {
            make_dirs(job.artifact_path);
            retained = join_path(job.artifact_path, "keep");
        } elif collision == "checksum" {
            retained += ".sha256";
        }
        write_text(retained, "existing winner");
        job.advance();
        assert job.done;
        assert job.error != "";
        assert read_text(retained) == "existing winner";
        assert len(list_dir(directory)) == 1;
    }
    job = seed_job(join_path(base, "cancelled"), "linux-x86_64");
    job.advance();
    job.cancel();
    job.advance();
    assert job.done;
    assert job.error == "Build cancelled.";
    assert len(list_dir(job.request.outputDirectory)) == 0;
    job = seed_job(join_path(base, "bad-archive"), "windows-x86_64");
    finish(job, "archive");
    writer = job.writer;
    assert writer is not None;
    writer.source_bytes = 4294967295;
    job.advance();
    assert job.done;
    assert job.error != "";
    assert len(list_dir(job.request.outputDirectory)) == 0;
}

with entry {
    assert len(sys.argv) == 2;
    staging = temp_dir(sys.argv[1], "bundlr-contract-");
    try {
        check_pins();
        check_rejections();
        check_git();
        check_cli();
        check_invalid_requests();
        print("Request validation passed.");
        check_directory_links(staging);
        check_metadata();
        check_default_entry_point(staging);
        print("Wheel and entry-point contracts passed.");
        check_archives(staging);
        check_path_cursor(staging);
        check_archive_metadata(staging);
        check_archive_case_collisions(staging);
        check_windows_launchers(staging);
        print(
            "Archive modes, virtual links, console and windowed launcher contracts passed."
        );
        suffix = ".exe" if sys.platform == "win32" else "";
        check_processes(
            join_path(parent_path(native_path(True)), "process-fixture" + suffix)
        );
        print("Process streaming and cancellation passed.");
        check_builds(staging);
        check_runtime_cache(staging);
        print(
            "Four-target layout, evidence, publication races, verified runtime cache and failure cleanup passed."
        );
        check_http();
        print(
            "Fragmented HTTP, chunked bodies, size limits and loopback authorization passed."
        );
    } finally {
        remove_tree(staging);
    }
}
