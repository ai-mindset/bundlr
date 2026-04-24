# bundlr

**Zero‑installation Python CLI runner** – execute any PyPI package or Git repository instantly without installing anything on the host system.

### Quick start

#### GUI mode (double‑click)
1. Download the appropriate executable from the **Releases** page.
2. Double‑click to launch the GUI.
3. Enter a package name (e.g. `cowsay`) and optional arguments.
4. Watch the tool run in a terminal window.

#### Command line
```bash
# Run a PyPI package
bundlr cowsay -t "Hello World"

# Run a tool from a Git repository
bundlr https://github.com/psf/black --help
```

### Build mode – create portable executables
> **Status**: Windows binaries are functional. Linux/macOS support is under development 🚧.

```bash
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
  * `--target <platform>` – target platform (`windows-x86_64`, `linux-x86_64`, `macos-aarch64`, …).
  * `--output <file>` – explicit output executable path.
  * `--output-dir <dir>` – directory for multi‑target builds.
  * `--python-version <ver>` – Python version to embed (default **3.14**).
  * `--optimise-size` – minimise binary size.
  * `--optimise-speed` – maximise runtime speed.
  * `--optimise-compatibility` – maximise compatibility (default).
  * `--exclude-dev-deps` – omit development dependencies.
  * `--entry-point <script>` – custom entry‑point Python code.

### Architecture overview
* **Bundlr core** – Zig binary that orchestrates downloading Python, creating a virtual environment, installing the package, and executing it.
* **Build pipeline** (`src/build/pipeline.zig`) – resolves dependencies, collects assets, prepares a Python runtime, and invokes the **BundleGenerator**.
* **BundleGenerator** (`src/build/bundle_generator.zig`) – generates the stub source, compiles it for the target, and appends the bundled archive.
* **RuntimeEmbedder**, **AssetCollector**, **DependencyResolver**, **GitArchiveManager**, **UvManager** – support modules handling Python runtime, wheels, dependency resolution, and Git archive extraction.

### Installation (manual)
```bash
# Clone and build from source
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr && zig build
# Executable will be in zig-out/bin/bundlr
```

### License
MIT
