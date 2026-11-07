import from src.domain.request { PYTHON_VERSION, PYTHON_BUILD, supported_target }
import hashlib;

def:pub runtime_cache_name(url: str, checksum: str) -> str {
    # A warm cache must not hide an inconsistent version/build/platform pin edit.
    identity = url + "\n" + checksum;
    return hashlib.sha256(identity.encode("utf-8")).hexdigest() + ".tar.gz";
}

obj:pub PythonDistribution {
    has target: str,
        triple: str,
        sha256: str,
        executable: str;

    def url -> str {
        return f"https://github.com/astral-sh/python-build-standalone/releases/download/{PYTHON_BUILD}/cpython-{PYTHON_VERSION}+{PYTHON_BUILD}-{self.triple}-install_only_stripped.tar.gz";
    }
}

def:pub distribution(target: str) -> PythonDistribution {
    if target == "linux-x86_64" {
        return PythonDistribution(
            target=target,
            triple="x86_64-unknown-linux-gnu",
            sha256="5854aa6ec71cad00334d5065633c210b2e7feb40956767a59a91791cadcf0b79",
            executable="bin/python3"
        );
    }
    if target == "macos-arm64" {
        return PythonDistribution(
            target=target,
            triple="aarch64-apple-darwin",
            sha256="9a1e9e06175c10efd8378b904b07fa21bd791ab3345d7cdffeb4a76c9ff55903",
            executable="bin/python3"
        );
    }
    if target == "macos-x86_64" {
        return PythonDistribution(
            target=target,
            triple="x86_64-apple-darwin",
            sha256="8e6b7e6533bdf746287008edf91102e7bee0a6ca1d24f16c4514237cafd706c5",
            executable="bin/python3"
        );
    }
    if target == "windows-x86_64" {
        return PythonDistribution(
            target=target,
            triple="x86_64-pc-windows-msvc",
            sha256="0d422a1439ec308e03f47df551bc30f5994727c456e414b026d202bcda9b7c1c",
            executable="python.exe"
        );
    }
    raise ValueError(f"Unsupported target: {target}");
}
