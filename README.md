# bundlr 📦

**Zero-installation Python CLI tool runner.** Execute any Python command-line tool instantly—no pip install, no virtual environments to manage, no dependency conflicts. Just run it.

Bundlr automatically downloads Python, creates isolated environments, installs packages, and executes commands—then cleans up. **Double-click for GUI mode** or use the command line for power users.

**Perfect for:**
- 🚀 Testing tools like `black`, `pytest`, or `httpie` without installing
- 🔧 Running utilities from GitHub repositories instantly
- 🧪 Trying packages without polluting your system Python
- 📦 One-off commands without environment setup
- 🛡️ Safe execution in isolated, temporary environments

## 🚀 Quick Start

### GUI Mode (Easiest!)
1. **Download** bundlr for your platform from [Releases](https://github.com/ai-mindset/bundlr/releases/latest)
2. **Double-click** the executable
3. **Enter** a package name (e.g., "cowsay") and arguments
4. **Watch** bundlr work in a live terminal window!

### Command Line Mode
```bash
# Execute Python tools instantly
bundlr cowsay -t "Hello World"          # ASCII art text
bundlr httpie GET httpbin.org/json      # HTTP client tool
bundlr black --help                     # Python code formatter

# Run from GitHub repositories
bundlr https://github.com/psf/black --help
bundlr https://github.com/ai-mindset/distil --help

# Create portable executables (Build Mode)
bundlr build cowsay --target linux-x86_64     # Linux executable
bundlr build httpie --target windows-x86_64   # Windows executable
bundlr build black --target macos-aarch64     # macOS Apple Silicon

# Launch GUI mode explicitly
bundlr --gui
```

## 🔨 Build Mode: Create Portable Executables

Bundlr can create **standalone, portable executables** that run anywhere without requiring bundlr to be installed on the target system. Perfect for distributing tools or deploying to servers.

### Features
- 📦 **Self-contained**: Includes Python runtime + dependencies
- 🌐 **Cross-platform**: Build for any supported platform from any platform
- ⚡ **Optimised**: Multiple optimisation levels for size vs speed
- 🚀 **No dependencies**: Generated executables run without installation

### Usage
```bash
# Basic build command
bundlr build <package> --target <platform>

# Available targets
bundlr build cowsay --target linux-x86_64                           # Linux
bundlr build cowsay --target macos-x86_64                           # macOS Intel
bundlr build cowsay --target macos-aarch64                          # macOS Apple Silicon
bundlr build cowsay --target windows-x86_64                         # Windows

# Build from GitHub repositories
bundlr build https://github.com/psf/black --target linux-x86_64

# Optimisation levels (optional)
bundlr build httpie --target linux-x86_64 --optimise-speed          # Faster execution
bundlr build httpie --target linux-x86_64 --optimise-size           # Smaller binary
bundlr build httpie --target linux-x86_64 --optimise-compatibility  # Default
```

Generated **self-extracting bundles** (~100-150MB) work on any system without Python/bundlr installed.

## 🤔 Why Bundlr?

**vs. pipx:** No installation required. Bundlr works instantly - no need to install pipx first.

**vs. Docker:** Faster startup, smaller footprint. No container overhead or Docker daemon required.

**vs. pip install:** Zero system pollution. Each run uses a fresh, isolated environment that's automatically cleaned up.

**vs. Git clone + setup:** Skip the clone, virtual environment creation, and dependency installation dance.

**vs. PyInstaller/cx_Freeze:** No need to install Python or packaging tools. Build cross-platform executables from any platform.

**Use cases:** Testing tools instantly, creating portable executables, CI/CD deployment, one-off scripts, air-gapped systems.

## 📥 Installation

**Download from [Releases](https://github.com/ai-mindset/bundlr/releases/latest):**
- **Linux**: `bundlr-linux-x86_64`
- **macOS**: `bundlr-macos-x86_64` (Intel) or `bundlr-macos-aarch64` (Apple Silicon)
- **Windows**: `bundlr-windows-x86_64.exe`

### Unix (Linux & macOS)
```bash
# Make executable and install
chmod +x bundlr-*
sudo mv bundlr-* /usr/local/bin/bundlr

# Test it
bundlr cowsay -t "Hello!"
```

### Windows
```cmd
# Rename for easier use (optional)
rename bundlr-windows-x86_64.exe bundlr.exe

# Test it
bundlr cowsay -t "Hello!"
```

### Build from Source
```bash
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr && zig build
# Binary in zig-out/bin/bundlr
```

## 🎯 How It Works

**Instant Execution** (`bundlr <package>`): Downloads Python 3.14 (~60MB), creates isolated environment, installs package, executes command. ~10s cold start, ~2s cached.

**Build Mode** (`bundlr build <package> --target <platform>`): Creates optimised Python runtime bundle, collects dependencies, generates cross-platform self-extracting executable. ~50s with caching optimisations.

- **Security**: Command injection prevention, isolated execution, no system pollution
- **Architecture**: Single Zig binary, 1GB cache limit, comprehensive testing


## ⚠️ Troubleshooting

| Problem | Solution |
|---------|----------|
| **"Permission denied"** (Unix) | `chmod +x bundlr-*` |
| **"Command not found"** | Add to PATH or use `./bundlr-*` |
| **Python download fails** | Check internet connection (~60MB download) |
| **GUI doesn't work** | Use CLI mode: `bundlr <package>` |

## ❓ FAQ

**Q: How is this different from pipx?**
A: Bundlr requires no installation - it's a single executable that automatically downloads Python and manages everything. pipx requires Python to already be installed.

**Q: Is it safe to run unknown packages?**
A: Yes. Each run uses a fresh, temporary virtual environment created from bundlr's own downloaded Python runtime, so your existing system Python and its global packages are never imported or modified. Bundlr only reads or writes files in its cache and in the locations you explicitly operate on.

**Q: Where are files stored?**
A: Platform-specific cache directories:
- Linux: `~/.cache/bundlr`
- macOS: `~/Library/Caches/bundlr`
- Windows: `%LOCALAPPDATA%\bundlr`

**Q: Can I use it for CI/CD?**
A: Absolutely! Perfect for running tools like black, pytest, or custom scripts without setup steps.

**Q: What Python version does it use?**
A: Python 3.14 by default, configurable via `BUNDLR_PYTHON_VERSION` environment variable.

**Q: How do portable executables work?**
A: Build mode creates self-extracting bundles (~100-150MB) that include Python runtime and all dependencies. They run on target systems without requiring bundlr or Python to be installed.

**Q: Can I distribute the generated executables?**
A: Yes! Generated executables are completely standalone and can be distributed freely. Recipients don't need Python, bundlr, or any dependencies installed.

## 📄 License

MIT
