# Bundlr 📦

Bundlr packages a pinned Python application from PyPI or HTTPS Git into a
self-contained application for Linux x64, Windows x64, or macOS ARM64/x64.
Recipients need neither Python, uv, Bundlr nor Odin installed.

The native Odin executable embeds its browser UI and verified uv payload. Build
and test tooling is also Odin; no host scripting runtime or package installation
is required.

## Build from source

Install the pinned Odin compiler: `odin version dev-2026-11-nightly:9a69916`,
commit `9a6991685ddf663956d9836602eb421e141fc443`. The compiler and standard library
are pinned together in `scripts/main.odin`; builds reject another revision.
Set `ODIN` to select a compiler path; paths containing spaces are supported.
Git and `tar` are host prerequisites. Linux uses system `libcurl.so.4`, macOS
uses system libcurl, and Windows links the pinned Odin distribution's curl
libraries. No OS packages are installed automatically.

If needed, `bash scripts/install_odin.sh` installs the checksum-pinned compiler
into a new `.build/odin-toolchain`. Add that directory to PATH. Windows bootstrap
uses Git Bash and system tar; Intel macOS requires existing LLVM 20 (`LLVM_CONFIG`)
because this compiler release has no Intel macOS binary.

Run from the repository root:

```sh
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- prepare-uv
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- build
```

The define lets the developer driver run before uv is prepared. Application
builds always require embedded uv.

Preparation verifies the release manifest and archive checksums.
`prepare-uv --prepared` checks existing payloads offline. Builds run an offline diagnostic
and produce an executable with JSON and `.sha256` sidecars. The default Linux
output is `dist/bundlr-linux-x86_64`; other hosts use corresponding filenames.
Outputs are never overwritten: pass a new path, such as `build dist/bundlr-next`,
to rebuild. Bounds checks, vet and strict style remain enabled.

## Use

Run without arguments for the browser interface, or use the CLI:

```sh
./dist/bundlr-linux-x86_64
./dist/bundlr-linux-x86_64 --name Black --command black --kind console black==26.5.1
```

For a Windows desktop application built on Linux:

```sh
./dist/bundlr-linux-x86_64 --name PipUI --command pip-ui --kind windowed \
  --target windows-x86_64 pip-ui-tkinter==0.2.0
```

Use `--target all` for all four targets. HTTPS Git sources may end in `@revision`;
prefer a full commit for reproducibility. Git URLs must be credential-free.
Dependencies need target-compatible wheels; Git roots must produce portable,
pure-Python wheels. Git build backends execute project code on the builder.

Packages with multiple commands require `--command`. Black has `black` and
`blackd`; enter `black` under **Application entry point** in the browser.
**Cancel** stops the build and subprocess descendants. **Quit Bundlr** waits for
cleanup and shuts down. The browser admits one active build.

The browser defaults to dark mode. **Dark mode** toggles the theme and saves the
choice for the current origin when storage is available. Both themes have visible
keyboard focus and contrast-checked colours.

Output defaults to `dist/`; change it with `--output PATH`. Send the complete
client archive and its `.sha256` file. Verify before extracting, for example:

```sh
(cd dist && sha256sum --check Black-linux-x86_64.tar.gz.sha256)
```

Applications include `bundlr-manifest.json`, `bundlr-dependencies.json`,
`THIRD_PARTY_LICENSES.txt` and `SHA256SUMS`. See
[IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md) for recipient support evidence.

Use `--help` for all options. `--diagnose` verifies and repairs uv offline.
`BUNDLR_CACHE_DIRECTORY` and
`BUNDLR_PYTHON_CACHE_DIRECTORY` select caches. `BUNDLR_UV_EXECUTABLE` must match
the pinned host checksum. `BUNDLR_NO_BROWSER=1` suppresses browser opening.
Python/package downloads need network access.

## Implementation

CLI and browser requests share validation and packaging. Targets build sequentially
with checksum-verified CPython 3.12.13 and uv 0.13.9. Dependency installation never
falls back to source builds.

Recipients run bundled Python in isolated mode and preserve literal arguments
after relocation. Windows uses ZIP archives and console/pythonw launchers; Unix
uses `tar.gz`, with macOS application bundles. Publication stages complete output
on the destination filesystem and rolls back partial results.

Odin emits Python launchers and test fixtures as application content; tests run
them with the verified bundled interpreter.

The browser server binds `127.0.0.1` on an ephemeral port, checks Host/session
token/Origin, uses CSP nonces and cancels builds on disconnection.

## Verification and release

Run checks with the same developer driver:

```sh
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- check
```

Replace `check` with a command below. Optional binaries default to the native
executable in `dist/`.

| Command | Checks |
| --- | --- |
| `check` | Debug/optimized units, filesystem/process integration, fresh build and compiled integrity; cleans its own temporary files |
| `verify [BINARY]` | CLI validation, offline uv extraction/repair and override/payload integrity without builder tools on PATH |
| `acceptance [BINARY] [NEW_DIR] [--all-targets]` | Real Black/Git builds, artifact evidence, dependency safety and relocated recipients; Windows also tests pythonw/Tk |
| `browser [BINARY]` | Real Chrome theme, validation, streaming, cancellation, concurrency, packaging and shutdown checks on Linux |
| `consume DIRECTORY` | Run matching Linux-built archives on their target host |

An explicit acceptance directory retains evidence. Set `BUNDLR_SMOKE_CHROME` if
Chrome/Chromium cannot be discovered. Downloads and loopback access are required.

Branch/PR CI checks Linux. Manual full runs and `v*` tags also require native
Windows/macOS and cross-host recipient checks. Tagged runs stamp the version and
publish only after every gate passes. Local checks do not certify a release.

Build on a controlled machine: Bundlr, Git build backends and recipient Python are
not security sandboxes.
