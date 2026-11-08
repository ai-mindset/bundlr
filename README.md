# Bundlr 📦

Package a pinned PyPI requirement or HTTPS Git project into a self-contained
Python application for Linux x64, Windows x64, or macOS ARM64/x64. Recipients need
no Python, Jac, uv, or Bundlr installation. Written in [Jac](https://jaclang.org),
with a native CLI and a local browser UI.

Bundled Python: **3.12.13**. Requires glibc **2.35+** on Linux or macOS **13.0+**.

## Usage

Download your **builder** platform's archive and matching `.sha256` from
[Releases](https://github.com/ai-mindset/bundlr/releases/latest). From the download
directory, copy the commands for your platform:

<details>
<summary>Linux x64</summary>

```sh
sha256sum --check bundlr-linux-x86_64.tar.gz.sha256 && \
tar -xzf bundlr-linux-x86_64.tar.gz && \
cd bundlr-linux-x86_64 && \
./bundlr --diagnose
```

</details>

<details>
<summary>macOS (Apple Silicon or Intel)</summary>

```sh
target="macos-$(uname -m)"
shasum -a 256 --check "bundlr-$target.tar.gz.sha256" && \
tar -xzf "bundlr-$target.tar.gz" && \
cd "bundlr-$target" && \
./bundlr --diagnose
```

</details>

<details>
<summary>Windows x64 (PowerShell)</summary>

```powershell
$ErrorActionPreference = 'Stop'
$archive = 'bundlr-windows-x86_64.zip'
$expected = (Get-Content "$archive.sha256").Split()[0]
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ine $expected) { throw 'Checksum mismatch' }
Expand-Archive $archive .
Set-Location bundlr-windows-x86_64
./bundlr.exe --diagnose
if ($LASTEXITCODE -ne 0) { throw 'Bundlr diagnostic failed' }
./bundlr.exe --command black --target all "black==26.5.1"
```

</details>

Linux/macOS examples, from the extracted directory:

```sh
./bundlr                       # Browser UI; use Quit Bundlr to stop
./bundlr --command black --target all "black==26.5.1"
./bundlr --name PipUI --command pip-ui --kind windowed \
  --target windows-x86_64 --output dist/pipui-0.2.0 "pip-ui-tkinter==0.2.0"
```

On Windows, run `./bundlr.exe` without arguments for the browser UI.

Sources must be `name[extras]==version` or an HTTPS Git URL. Git URLs accept
`git+`, `@revision`, and `#subdirectory=...`; use a full commit for reproducibility.
Git builds require system Git and can execute the project's build backend.
Run builds on a controlled builder; Bundlr is not a security sandbox.

Options precede the source. `--name`, `--command`, and `--kind` override detection;
repeat `--target` or use `all`. Run `--help` for the complete CLI.

| Target | Application | Archive |
| --- | --- | --- |
| `linux-x86_64` | `Name-linux-x86_64/Name` | `.tar.gz` |
| `windows-x86_64` | `Name-windows-x86_64/Name.exe` | `.zip` |
| `macos-arm64` | `Name-macos-arm64.app` | `.tar.gz` |
| `macos-x86_64` | `Name-macos-x86_64.app` | `.tar.gz` |

Deliver the archive and its checksum, and extract the entire application before
launching. Use archives for Unix targets built on Windows or case-insensitive
volumes so target paths, symlinks, and permission metadata reach the recipient.

## Guarantees and support

- Python and uv downloads are SHA-256 verified; cached bytes are checked before use.
- Target dependencies require compatible wheels. Git root wheels must be pure
  Python with portable tags; packaging never runs foreign target executables.
- Launchers use bundled Python with `-I -B`, independently of the builder's Python.
- Completed directories, archives, and checksums are never overwritten. Use a new
  output directory for subsequent builds.
- The native executable and complete compressed Bundlr release must each stay
  below **50 MiB**. Releases include a `.size.json` report.

Applications include `bundlr-manifest.json`, `bundlr-dependencies.json`,
`THIRD_PARTY_LICENSES.txt`, and `SHA256SUMS` at their root (`Contents/Resources`
on macOS). Archive checksums cover the complete application; these records are not
signatures or vulnerability assessments. See [IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md)
for their meaning and deployment checks.

## Configuration

| Variable | Purpose |
| --- | --- |
| `BUNDLR_CACHE_DIRECTORY` | Override the platform's Bundlr runtime cache directory. |
| `BUNDLR_PYTHON_CACHE_DIRECTORY` | Store Python archives separately from the tool cache. |
| `BUNDLR_UV_EXECUTABLE` | Use a host uv binary matching the compiled checksum. |
| `BUNDLR_CA_BUNDLE` | Select a CA bundle for Bundlr's HTTPS downloads. |

Python archives are cached by URL and SHA-256, verified on reuse, and repaired
if corrupt. uv uses its own certificate and proxy configuration.

## Development

Requires CMake **3.25+**, Git, a native C/C++ toolchain, Ninja, patchelf, autotools
and Chrome.
From the repository root on Linux, install the pinned Jac and run all checks:

```sh
bash <<'BUILD'
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash -s -- --version 0.39.1
export PATH="$HOME/.local/bin:$PATH"
export JAC_CACHE_HOME="$PWD/.build/jac-cache"
mkdir -p .build
release_dir="$(mktemp -d "$PWD/.build/release-XXXXXXXX")"
jac run scripts/prepare_uv.jac --target linux-x86_64
jac fmt --check src scripts tests ui
jac check src scripts tests ui --lint
jac check src scripts tests ui
jac run scripts/build.jac --prepared-uv --output "$release_dir"
jac test
"$release_dir/bundlr-linux-x86_64/bundlr" --diagnose
jac run scripts/smoke.jac --runtime "$release_dir/bundlr-linux-x86_64" --browser
BUILD
```

Each run uses a fresh output directory because completed releases are never
overwritten. The helper builds pinned vcpkg dependencies; `jac test` runs native
contracts against them. Browser smoke tests require Chrome and loopback access.

For cross-builds, pass `--target TARGET --native-libs PATH` with that target's CI
dependency bundle. Set `BUNDLR_TEST_TARGET` and `BUNDLR_TEST_NATIVE_LIBS` to match
before `jac test`. Jac compatibility fixes run automatically. Keep a separate,
absolute `JAC_CACHE_HOME` for each concurrent target.

CI checks all four hosts on PRs, `main`, `v*` tags and manual runs. Pinned compiler,
native dependencies and compilation outputs are cached. All native, browser, GUI
and cross-platform recipient checks must pass before tag releases publish.
Require **Production readiness (all four hosts)** in branch protection.
