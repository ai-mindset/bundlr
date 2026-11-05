import from src.domain.request {
    parse_source,
    parse_cli,
    validate_request,
    PackageRequest,
    PackageSource
}

def:pub check_pins {
    assert parse_source(" black==26.5.1 ").value == "black==26.5.1";
    assert parse_source("demo[gui,colour]==1.2.0rc1").inferred_name == "demo";
    assert parse_source("a[my--extra]==1").inferred_name == "a";
}

def:pub check_rejections {
    for value in [
        "",
        "black",
        "black>=1",
        "black==1.*",
        # Regression: malformed identifiers must fail before build output exists.
        "demo[,]==1",
        "demo[gui,]==1",
        "demo[-gui]==1",
        "demo[gui-]==1",
        "demo.==1",
        "http://example.com/app.git",
        "./local-app"
    ] {
        caught = False;
        try {
            parse_source(value);
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
}

def:pub check_git {
    source = parse_source(
        "git+https://github.com/example/demo.git@abc123#subdirectory=app"
    );
    assert source.kind == "git";
    assert source.value
        == "https://github.com/example/demo.git@abc123#subdirectory=app";
    assert source.inferred_name == "demo";
}

def:pub check_cli {
    request = parse_cli(["--target", "windows-x86_64", "black==26.5.1"]);
    assert request.applicationName == "black";
    assert request.applicationKind == "auto";
    assert request.python == "3.12";
    explicit = parse_cli(
        [
            "package",
            "-n",
            "Black",
            "-c",
            "black",
            "-k",
            "console",
            "-t",
            "all",
            "black==26.5.1"
        ]
    );
    assert len(explicit.targets) == 4;
    assert explicit.command == "black";
}

def:pub check_invalid_requests {
    cases: list[list[str]] = [
        ["--target", "all", "--target", "windows-x86_64", "demo==1"],
        ["--target", "unknown", "demo==1"],
        ["--python", "3.11", "demo==1"],
        ["--name", "../escape", "demo==1"],
        ["--kind", "unknown", "demo==1"],
        ["--unknown", "x", "demo==1"],
        ["demo==1", "trailing"]
    ];
    for args in cases {
        caught = False;
        try {
            parse_cli(args);
        } except ValueError {
            caught = True;
        }
        assert caught;
    }
}
