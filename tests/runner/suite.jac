"""Route jac test through the same native contract helper used by release CI."""
import os;
import subprocess;
import from pathlib { Path }
import from scripts.prepare_uv { host_target }

test "native contract suite" {
    project_root = Path(__file__).resolve().parents[2];
    target = os.environ.get("BUNDLR_TEST_TARGET", host_target());
    libraries = Path(
        os.environ.get(
            "BUNDLR_TEST_NATIVE_LIBS",
            str(project_root / ".build/native" / target / "portable-libs")
        )
    );
    if not libraries.is_absolute() {
        libraries = project_root / libraries;
    }
    assert (libraries / "native-dependencies.json").is_file() , (
        f"Missing pinned native dependency bundle: {libraries}. "
        "Run 'jac run scripts/build.jac' first, or set BUNDLR_TEST_NATIVE_LIBS "
        "to an existing target bundle."
    );
    subprocess.run(
        [
            "jac",
            "run",
            "scripts/test.jac",
            "--target",
            target,
            "--native-libs",
            str(libraries)
        ],
        cwd=project_root,
        check=True
    );
}
