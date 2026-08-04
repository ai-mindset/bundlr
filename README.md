# Bundlr 📦

<<<<<<< HEAD
Bundlr turns a Python application from PyPI or HTTPS Git into a self-contained, double-clickable
application for Windows, macOS, and Linux. Recipients do not need Python, uv, Deno, or Bundlr.

## Package an application

Open Bundlr, paste a pinned package source, select the targets, and click **Package**. Bundlr
detects the application name, entry point, and console/GUI type when possible.

CLI examples:

```sh
bundlr --target all example-app==1.2.3

bundlr --target all \
  https://github.com/example/example-app.git@0123456789abcdef0123456789abcdef01234567
```

Use `--name`, `--command`, or `--kind` only when automatic detection is ambiguous.

Each target produces:

- A relocatable application directory with a double-click launcher.
- A client ZIP or `tar.gz` archive.
- SHA-256 checksums, dependency inventory, licence notices, and build metadata.

## How cross-target packaging works

Bundlr combines a checksum-pinned target
[Python runtime](https://github.com/astral-sh/python-build-standalone) with target-compatible wheels
selected by [uv](https://docs.astral.sh/uv/). It does not use PyInstaller or execute foreign target
binaries while packaging.

Supported applications are:

- Pure Python; or
- Dependent on native packages that publish wheels for every selected target.

Bundlr rejects missing target wheels and Git projects that build host-specific native code. This
prevents a Linux binary from being accidentally delivered in a Windows or macOS application.

## Prototype status

- One Linux command successfully generated Linux x64, Windows x64, macOS ARM64, and macOS Intel
  archives.
- The Linux application launched successfully; foreign executables and all archive checksums were
  verified structurally.
- The four client archives measured 23–33 MiB.
- Formatting, linting, type checking, and 35 tests pass.
- Native Windows and macOS launch testing remains required before client release.

Bundlr and generated applications are currently unsigned. Corporate controls, SmartScreen, or
Gatekeeper may require IT approval; use [IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md).

## Development

Requires Deno 2.9.4 or later.

```sh
deno task check
deno task test
deno task build
```

GitHub Actions publishes Bundlr releases. Client applications are built locally by Bundlr and do not
depend on CI.
=======
**Zero-installation Python CLI runner** — run any PyPI package or GitHub/Codeberg/GitLab repository instantly, with no host-side installation required.

## Quick start

### GUI mode (double-click)
1. Download the appropriate executable from the **Releases** page.
2. Double-click to launch the GUI.
3. Enter a PyPI package name or Git URL (e.g. `cowsay`) and optional arguments.

### Command line
```bash
# Run a PyPI package
bundlr cowsay -t "Hello World"

# Run from a Git repository
bundlr https://github.com/psf/black --help
bundlr https://codeberg.org/user/repo
```

## Build mode — create portable executables

> **Status**: Windows executables are functional. Linux/macOS build support is in active development 🚧.

```bash
# Build for the default target (linux-x86_64)
bundlr build cowsay

# Build a Windows executable
bundlr build cowsay --target windows-x86_64
```

The produced executable is self-extracting: it contains a Zig stub, a Python runtime, all required wheels, and bundle metadata. On first run the stub extracts everything to a temporary directory, sets up the environment, and launches the entry point.

### Build options

| Flag | Description |
|---|---|
| `--target <platform>` | Target platform (`windows-x86_64`, `linux-x86_64`, `macos-aarch64`, …). Default: `linux-x86_64` |
| `--output <file>` | Explicit output path |
| `--output-dir <dir>` | Directory for multi-target builds |
| `--python-version <ver>` | Python version to embed (default: **3.14**) |
| `--optimise-size` | Minimise binary size |
| `--optimise-speed` | Maximise runtime speed |
| `--optimise-compatibility` | Maximise compatibility |
| `--exclude-dev-deps` | Omit development dependencies |
| `--entry-point <script>` | Custom entry-point Python code |

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `BUNDLR_PYTHON_VERSION` | `3.14` | Python version to use |
| `BUNDLR_GIT_BRANCH` | `main` | Git branch to check out |
| `BUNDLR_CACHE_DIR` | platform default | Custom cache directory |
| `BUNDLR_PROJECT_NAME` | — | Override project name |
| `BUNDLR_GIT_REPOSITORY` | — | Git repository URL (activates Git mode) |
| `BUNDLR_GIT_TAG` | — | Git tag to use |
| `BUNDLR_GIT_COMMIT` | — | Git commit hash to use |
| `BUNDLR_FORCE_REINSTALL` | `false` | Force reinstallation |

## Build from source

Requires [Zig](https://ziglang.org/).

```bash
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr && zig build
# Executable: zig-out/bin/bundlr
```

## Architecture

| Module | File | Role |
|---|---|---|
| Core | `src/main.zig` | CLI entry point, dispatch |
| Config | `src/config.zig` | Flags, env vars, defaults |
| Build pipeline | `src/build/pipeline.zig` | Orchestrates dependency resolution, asset collection, runtime embedding |
| Bundle generator | `src/build/bundle_generator.zig` | Compiles Zig stub, appends bundle archive |
| Dependency resolver | `src/build/dependency_resolver.zig` | Resolves and downloads wheels |
| Runtime embedder | `src/build/runtime_embedder.zig` | Embeds Python standalone distribution |
| Asset collector | `src/build/asset_collector.zig` | Collects wheels and assets |
| uv manager | `src/uv/bootstrap.zig` | Bootstraps and manages `uv` |
| Git archive | `src/git/archive.zig` | Downloads/extracts GitHub, Codeberg, GitLab archives (no `git` binary needed) |
| Python distribution | `src/python/distribution.zig` | Downloads and caches Python standalone builds |
| GUI | `src/gui/simple_dialogues.zig` | Cross-platform interactive GUI |
| Platform utilities | `src/platform/` | HTTP, path, process helpers |

## License

MIT
>>>>>>> origin/main
