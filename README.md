# bundlr

**Zero‑installation Python CLI runner** – execute any PyPI package or GitHub repository instantly without installing anything on the host system.

### Quick start

#### GUI mode (double‑click)
1. Download the appropriate executable from the **Releases** page.
2. Double‑click to launch the GUI.
3. Enter a PyPI package name or GitHub URL (e.g. `cowsay`) and optional arguments.
4. Watch the tool run in a terminal window.

#### Command line
```bash
# Run a PyPI package
bundlr cowsay -t "Hello World"

# Run a tool from a GitHub repository
bundlr https://github.com/psf/black --help
```

### Build mode – create portable executables
> **Status**: Windows binaries are functional. Linux/macOS support is under development 🚧.

```bash
# Build for the default target (linux-x86_64)
bundlr build cowsay

# Build a Windows executable
bundlr build cowsay --target windows-x86_64
```

#### What the build produces
* A **self‑extracting executable** that contains:
  * A tiny Zig stub (generated from `src/build/bundle_generator.zig`).
  * The selected Python runtime.
  * All required wheels and assets.
  * Metadata describing the bundle.
* When executed, the stub extracts the bundled data to a temporary directory, sets up the Python environment, and runs the requested entry point.

### Options (common to both run and build modes)
* `--help`, `-h` – show help.
* `--gui` – force GUI mode.
* Build‑specific flags:
  * `--target <platform>` – target platform (`windows-x86_64`, `linux-x86_64`, `macos-aarch64`, …). Default: `linux-x86_64`.
  * `--output <file>` – explicit output executable path.
  * `--output-dir <dir>` – directory for multi‑target builds.
  * `--python-version <ver>` – Python version to embed (default **3.14**).
  * `--optimise-size` – minimise binary size.
  * `--optimise-speed` – maximise runtime speed.
  * `--optimise-compatibility` – maximise compatibility.
  * `--exclude-dev-deps` – omit development dependencies.
  * `--entry-point <script>` – custom entry‑point Python code.

### Environment variables
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

### Architecture overview
* **Bundlr core** – Zig binary that orchestrates downloading Python, creating a virtual environment, installing the package, and executing it.
* **Build pipeline** (`src/build/pipeline.zig`) – resolves dependencies, collects assets, prepares a Python runtime, and invokes the **BundleGenerator**.
* **BundleGenerator** (`src/build/bundle_generator.zig`) – generates the stub source, compiles it for the target, and appends the bundled archive.
* **RuntimeEmbedder**, **AssetCollector**, **DependencyResolver** – build support modules handling Python runtime embedding, wheel collection, and dependency resolution.
* **GitArchiveManager** (`src/git/archive.zig`) – downloads and extracts GitHub repository archives (no `git` binary required).
* **DistributionManager** (`src/python/distribution.zig`) – manages Python standalone distribution downloads and caching.
* **UvManager** (`src/uv/bootstrap.zig`) – bootstraps and manages the `uv` package manager for fast virtual environment creation and package installation.

> **Note:** Git repository support currently targets **GitHub** only. GitLab and Codeberg support is planned.

### Installation (manual)
```bash
# Clone and build from source
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr && zig build
# Executable will be in zig-out/bin/bundlr
```

### License
MIT
