"""Use the pinned compiler's ES emitter and prelude; no npm/browser runtime is shipped."""
import argparse;
import shutil;
import from pathlib { Path }
import from jaclang.compiler.driver.program { JacProgram }
import from jaclang.compiler.backends.es.jac_runtime_js {
    write_jac_prelude_file,
    point_jac_prelude_at
}

def:pub build_ui(destination: Path) {
    destination.mkdir(parents=True, exist_ok=True);
    program = JacProgram();
    module = program.compile(file_path="ui/main.jac");
    if program.errors_had {
        raise RuntimeError(
            "Browser compilation failed: "
                + "\n".join(str(item) for item in program.errors_had)
        );
    }
    javascript = module.gen.js;
    if not javascript {
        raise RuntimeError("The browser compiler produced no JavaScript.");
    }
    (destination / "ui.js").write_text(
        point_jac_prelude_at(javascript), encoding="utf-8"
    );
    write_jac_prelude_file(str(destination));
    for name in ["index.html", "style.css"] {
        shutil.copy2(Path("ui") / name, destination / name);
    }
}

with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument("destination");
    build_ui(Path(parser.parse_args().destination));
}
