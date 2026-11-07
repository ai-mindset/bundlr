# Bundlr 📦

Bundlr packages a pinned PyPI requirement or HTTPS Git project into a self-contained
Python application for Linux x64, Windows x64, or macOS ARM64/x64. Recipients need
no Python, Jac, uv, or Bundlr installation.

Written in [Jac](https://jaclang.org), with a native CLI and a local browser UI
sharing one streamed, cancellable packaging engine. Bundled Python: **3.12.13**.

## Usage

Download the release for your **builder** platform, verify its `.sha256`, and
extract the complete directory. Run `bundlr` (`bundlr.exe` on Windows) without
arguments to open the browser UI. Use **Quit Bundlr** to stop it.

```sh
./bundlr --diagnose
./bundlr --command black --target all "black==26.5.1"
./bundlr --name PipUI --command pip-ui --kind windowed \
  --target windows-x86_64 --output dist/pipui-0.2.0 "pip-ui-tkinter==0.2.0"
```

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

## Packaging guarantees

- Python and uv downloads are SHA-256 verified; cached bytes are checked before use.
- Target dependencies require compatible wheels. Git root wheels must be pure
  Python with portable tags; foreign target executables are never run during packaging.
- Launchers use bundled Python with `-I -B`, independently of the builder's Python.
- Completed directories, archives, and checksums are never overwritten. Use a new
  output directory for subsequent builds.
- The native executable and complete compressed Bundlr release must each stay
  below **50 MiB**. Releases include a `.size.json` report.

## Verification and support

Verify archives with `sha256sum --check FILE.sha256` on Linux,
`shasum -a 256 --check FILE.sha256` on macOS, or compare `Get-FileHash` output with
its checksum file on Windows.

Each application includes these files at its root, or in `Contents/Resources` on macOS:

- `bundlr-manifest.json`: application, source, entry point, target, and version identity.
- `bundlr-dependencies.json`: installed distribution names and versions.
- `THIRD_PARTY_LICENSES.txt`: runtime and distribution licence notices.
- `SHA256SUMS`: sorted regular-file hashes relative to that directory, excluding itself.

The archive checksum covers the complete application. These records are not
signatures or vulnerability assessments. See [IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md)
for deployment evidence and clean-device acceptance.

## Configuration

| Variable | Purpose |
| --- | --- |
| `BUNDLR_CACHE_DIRECTORY` | Override the platform's Bundlr runtime cache directory. |
| `BUNDLR_PYTHON_CACHE_DIRECTORY` | Store Python archives separately from the tool cache. |
| `BUNDLR_UV_EXECUTABLE` | Use a host uv binary matching the compiled checksum. |
| `BUNDLR_CA_BUNDLE` | Select a CA bundle for Bundlr's HTTPS downloads. |

Python archives are keyed by URL and pinned SHA-256. Every reuse is verified;
corrupt entries are downloaded again, and partial downloads are removed on failure
or cancellation. uv uses its own certificate and proxy configuration.

## Development

Requires **Jac 0.39.1**, CMake 3.25+, Git, a native C toolchain, and the platform SDK.
Linux also needs Ninja, patchelf, and autotools. Install Jac using the
[official installer](https://jaclang.org/docs/latest/quick-guide/install).

From the repository root on Linux:

```sh
export JAC_CACHE_HOME="$PWD/.build/jac-cache"
jac run scripts/prepare_uv.jac --target linux-x86_64
jac fmt --check src scripts tests ui
jac check src scripts tests ui --lint
jac check src scripts tests ui
jac run scripts/build.jac --prepared-uv
jac test
dist/bundlr-linux-x86_64/bundlr --diagnose
jac run scripts/smoke.jac --runtime dist/bundlr-linux-x86_64 --browser
```

The build helper prepares pinned vcpkg libraries and uv, then writes the release
to `dist/`. Use the matching host target and paths on other platforms.

`jac test` delegates to the native contract suite. Set `BUNDLR_TEST_NATIVE_LIBS`
for a bundle outside `.build/native/HOST/portable-libs`, and `BUNDLR_TEST_TARGET`
for cross-compilation. Browser checks require Chrome.

Build helpers prepare Jac's Windows compiler workaround automatically. For direct
native builds, first run `jac run scripts/prepare_jac.jac --target TARGET`. Keep an
absolute `JAC_CACHE_HOME` separate for each concurrent target.

`build.jac --native-libs PATH --target TARGET` accepts a matching dependency bundle.
`--prepared-uv` reuses verified prepared bytes. `--development-libs PATH` produces
diagnostic `bundlr-dev-*` builds, not production release evidence.

CI runs on PRs, `main`, version tags, and manual dispatches. It caches dependencies
and verified runtime archives, builds platforms independently, and checks native,
browser, GUI, and cross-platform recipient behavior. Require **Production readiness
(all four hosts)** in branch protection; releases require every check to succeed.
