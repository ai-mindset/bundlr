import os;
import re;
import from pathlib { Path }

with entry:__main__ {
    tag = os.getenv("BUNDLR_RELEASE_TAG", "");
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?", tag) is None {
        raise ValueError("Invalid release tag: " + tag);
    }
    path = Path("src/domain/request.jac");
    (source, replacements) = re.subn(
        r'BUNDLR_VERSION: str = "[^"]+"',
        'BUNDLR_VERSION: str = "' + tag[1:] + '"',
        path.read_text()
    );
    if replacements != 1 {
        raise RuntimeError("Missing Bundlr version declaration.");
    }
    path.write_text(source);
}
