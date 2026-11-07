"""Exercise the native regex runtime without Bundlr's third-party DLL bundle."""
import re;

with entry {
    assert re.fullmatch(r"[a-z]+", "bundlr") is not None;
    assert re.fullmatch(r"[a-z]+", "123") is None;
    print("Windows compiler runtime acceptance passed.");
}
