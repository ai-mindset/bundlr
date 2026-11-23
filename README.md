# Bundlr 📦

Bundlr packages a pinned Python application from PyPI or HTTPS Git into a
self-contained application for Linux x64, Windows x64, or macOS ARM64/x64.
Recipients need neither Python, uv, Bundlr nor Odin installed.

The builder is a native Odin executable with its browser interface and verified
uv payload embedded. Its build driver, unit tests, integration checks, archive
reader, recipient checks and Chrome driver are also Odin. There is no scripting
runtime, package manager or second language toolchain to install for development.

## Build from source

Install the pinned Odin compiler: `odin version dev-2026-11-nightly:9a69916`,
commit `9a6991685ddf663956d9836602eb421e141fc443`. The compiler and standard library
are pinned together in `scripts/main.odin`; builds reject another revision.
Git and `tar` are host prerequisites. Linux uses system `libcurl.so.4`, macOS
uses system libcurl, and Windows links the pinned Odin distribution's curl
libraries. No OS packages are installed automatically.

The optional `bash scripts/install_odin.sh` bootstraps the checksum-pinned compiler
into a new `.build/odin-toolchain` using platform tools. It never replaces an
existing installation or changes shell profiles. Add that directory to PATH for
the current shell. Windows bootstrap uses Git Bash and system tar. The pinned
release has no Intel macOS binary; compiler bootstrap there requires an existing
LLVM 20 (`LLVM_CONFIG`). An already installed matching Odin needs no bootstrap.

Run from the repository root:

```sh
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- prepare-uv
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- build
```

The define applies to the developer driver so it can prepare uv in a clean
checkout. The driver builds the application with embedded uv enabled. An
application built with embedding disabled refuses to run.

Use `prepare-uv --prepared` to verify existing payload files offline. Preparation
checks the pinned release's checksum manifest and archive before extracting uv.
Application builds embed the compressed executable and its provenance, then run
an offline diagnostic before publishing the executable and its JSON/`.sha256`
sidecars. Existing outputs are never overwritten. Select a new output path to
rebuild:

```sh
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- build dist/bundlr-next
```

The default Linux output is `dist/bundlr-linux-x86_64`; Windows/macOS use their
corresponding native filenames. Bounds checks, vet and strict style stay enabled.

## Use

Run without arguments for the browser interface, or use the CLI:

```sh
./dist/bundlr-linux-x86_64
./dist/bundlr-linux-x86_64 --help
./dist/bundlr-linux-x86_64 --diagnose
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

The browser starts in dark mode. Use **Dark mode** to switch themes; your choice
is remembered for the current browser origin when storage is available. Both
themes use explicit contrast colours, visible keyboard focus and readable logs.

Output defaults to `dist/`; change it with `--output PATH`. Send the complete
client archive and its `.sha256` file. Verify before extracting, for example:

```sh
(cd dist && sha256sum --check Black-linux-x86_64.tar.gz.sha256)
```

Applications include `bundlr-manifest.json`, `bundlr-dependencies.json`,
`THIRD_PARTY_LICENSES.txt` and `SHA256SUMS`. See
[IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md) for recipient support evidence.

`--diagnose` verifies and repairs uv offline. `BUNDLR_CACHE_DIRECTORY` and
`BUNDLR_PYTHON_CACHE_DIRECTORY` select caches. `BUNDLR_UV_EXECUTABLE` must match
the pinned host checksum. `BUNDLR_NO_BROWSER=1` suppresses browser opening.
Python/package downloads need network access.

## Implementation

CLI and browser requests share the Odin packaging pipeline. Validation precedes
output creation. Targets build sequentially, with verified CPython 3.12.13
archives and uv 0.13.9. Dependency installation cannot fall back to source builds.
Git roots build separately before target-specific dependency resolution.

Recipients use bundled Python in isolated mode, preserve literal arguments and
work after relocation. Windows uses console/pythonw launcher stubs with appended
ZIPs; macOS uses application bundles. Windows archives use the native classic
ZIP writer with size/entry guards; Unix archives use `tar.gz`. Publication stages
on the output filesystem, refuses replacement and rolls back partial results.

Python launcher text and Python Git fixture source are application content
emitted by Odin. Tests that execute it use the downloaded, checksum-verified
bundled interpreter, never a host Python installation.

The loopback server binds `127.0.0.1` on an ephemeral port and checks the exact
Host, session token and supplied Origin. It retains CSP nonces, bounded HTTP
framing, NDJSON backpressure, cancellation and disconnect cleanup.

## Verification and release

The same native driver runs all checks. No package installation is needed:

```sh
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- check
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- verify dist/bundlr-linux-x86_64
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- acceptance dist/bundlr-linux-x86_64
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- browser dist/bundlr-linux-x86_64
```

`check` runs debug/optimized source and protocol tests, a clean developer-tool
bootstrap without prepared payloads, real filesystem/process integration, a
fresh application build and compiled integrity. It removes only its owned
working directory. `verify` checks CLI validation, uv extraction, cache repair,
permissions, symlinks, override identity and embedded-payload tampering with
builder tools absent from PATH.

`acceptance` packages pinned Black and deterministic Git fixtures, checks
collisions and artifact evidence, rejects nonportable roots, executes native
recipients, and tests dependency markers, cycles, source-build prohibition,
root identity and launcher isolation using verified bundled Python. Windows
also exercises pythonw/Tk. `managed` runs those interpreter/resolver regressions
independently after obtaining the verified host runtime.

Append a new evidence directory and `--all-targets` to `acceptance` to retain
all-target output. On recipient hosts, `consume DIRECTORY` checks matching
Linux-built archives. `browser` requires real Chrome/Chromium on Linux; select it
with `BUNDLR_SMOKE_CHROME`. The Odin driver speaks Chrome's debugging protocol
directly and checks the rendered client, validation, streaming, cancellation,
concurrency, packaging, recipient execution and shutdown. Client stream-state
regressions execute inside Chrome, without a separate JavaScript runtime.

CI retains every native, packaging, browser and cross-host release gate. Tagged
runs stamp `src/common.odin` through the native `stamp-version` command and
`BUNDLR_RELEASE_TAG`; normal builds do not stamp the checkout. Use
`git diff --check` when editing source, configuration or documentation.

The rewrite is **not release-certified**. See
[tests/VALIDATION.md](tests/VALIDATION.md) for current evidence and blocked gates.
Build on a controlled machine: Bundlr, Git build backends and recipient Python
are not security sandboxes.
