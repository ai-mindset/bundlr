# bundlr 📦

Run any Python CLI tool instantly without installation hassles. **Double-click for a friendly GUI** or use the command line for power users.

**Perfect for:**
- 🚀 Trying Python CLI tools without installing them
- 🔧 Running tools from GitHub repositories
- 🧪 Testing packages quickly
- 📦 One-off commands without setup

## 🚀 Quick Start

### GUI Mode (Easiest!)
1. **Download** bundlr for your platform from [Releases](https://github.com/ai-mindset/bundlr/releases/latest)
2. **Double-click** the executable
3. **Enter** a package name (e.g., "cowsay") and arguments
4. **Watch** bundlr work in a live terminal window!

### Command Line Mode
```bash
# Run any PyPI package
bundlr cowsay -t "Hello World"
bundlr httpie GET httpbin.org/json

# Run from GitHub
bundlr https://github.com/psf/black --help
bundlr https://github.com/ai-mindset/distil --help

# Launch GUI mode explicitly
bundlr --gui
```

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
bundlr cowsay "Hello!"
```

### Windows
```cmd
# Rename for easier use (optional)
rename bundlr-windows-x86_64.exe bundlr.exe

# Test it
bundlr cowsay "Hello!"
```

### Build from Source
```bash
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr && zig build
# Binary in zig-out/bin/bundlr
```

## 🎯 How It Works

bundlr automatically handles everything:

1. **🐍 Downloads Python** (3.14) if needed
2. **📦 Creates isolated environment** - no system conflicts
3. **⬇️ Installs packages** - pip for PyPI, uv for Git repos
4. **▶️ Runs your command** - with all your arguments
5. **🧹 Cleans up** - removes temporary files

### Two Ways to Use

| **GUI Mode** | **CLI Mode** |
|--------------|--------------|
| `bundlr` (no args) → Double-click behavior | `bundlr <package> [args]` → Command line |
| Friendly dialogs for package/args | Direct command execution |
| Live terminal output window | Output in current terminal |
| Perfect for beginners | Perfect for power users |

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

## 📄 License

MIT
