"""Exercise the native regex runtime without Bundlr's third-party DLL bundle."""
import re;

with entry {
    for _ in range(3) {
        re.purge();
        for _ in range(3) {
            assert re.fullmatch(r"[a-z]+", "bundlr") is not None;
            assert re.fullmatch(r"[a-z]+", "123") is None;
        }
    }
    print("Windows compiler runtime acceptance passed.");
}
