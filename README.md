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
# Popular CLI tools
bundlr cowsay -t "Hello World"          # ASCII art text
bundlr httpie GET httpbin.org/json      # HTTP client tool
bundlr black --help                     # Python code formatter

# Run from GitHub repositories
bundlr https://github.com/psf/black --help
bundlr https://github.com/ai-mindset/distil --help

# Launch GUI mode explicitly
bundlr --gui
```

## 🤔 Why Bundlr?

**vs. pipx:** No installation required. Bundlr works instantly - no need to install pipx first.

**vs. Docker:** Faster startup, smaller footprint. No container overhead or Docker daemon required.

**vs. pip install:** Zero system pollution. Each run uses a fresh, isolated environment that's automatically cleaned up.

**vs. Git clone + setup:** Skip the clone, virtual environment creation, and dependency installation dance.

**When to use Bundlr:**
- Quickly testing unfamiliar Python tools
- Running CI/CD tasks without environment setup
- Executing one-off scripts from GitHub
- Safely trying potentially problematic packages
- Working on systems where you can't install packages globally

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

Bundlr creates completely isolated execution environments for each command:

1. **🐍 Python Distribution** - Downloads Python 3.14 from python-build-standalone if not cached (~60MB, one-time)
2. **🔒 Isolated Environment** - Creates fresh virtual environment in platform-specific cache
3. **📦 Smart Installation** - Uses **pip** for PyPI packages, **uv** for Git repositories with automatic dependency resolution
4. **▶️ Command Execution** - Runs your specified command with all arguments in the isolated environment
5. **🧹 Automatic Cleanup** - Removes temporary files while preserving cache for faster subsequent runs

**Technical Details:**
- **Security-first**: Command injection prevention, isolated execution, no system pollution
- **Performance**: Cold start ~10s (download), warm start ~2s (cached), 1GB cache limit
- **Architecture**: Single Zig binary, no runtime dependencies, comprehensive testing


## 🛠 Platform Support

✅ **Linux** (x86_64) - Fully supported
✅ **macOS** (Intel & Apple Silicon) - Native support
✅ **Windows** (x86_64) - Complete support

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

## 📄 License

MIT
