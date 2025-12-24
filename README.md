# bundlr 📦

Run ANY Python package from PyPI or Git with zero setup! No Python installation required, no virtual environments to manage—just download and go.

## What is bundlr?

bundlr lets you instantly run Python command-line tools without installation hassles. Just type `bundlr` followed by the package name, and bundlr handles everything else automatically.

**Perfect for:**
- 🚀 Trying out Python CLI tools without installing them
- 🔧 Running tools from GitHub repositories
- 🧪 Testing different versions of packages
- ⚡ Quick one-off commands without setup

## Installation

### Option 1: Download Pre-Built Binary (Easiest!)

Download the latest version for your platform from the [Releases page](https://github.com/ai-mindset/bundlr/releases):

- **Linux**: `bundlr-linux-x86_64`
- **macOS (Intel)**: `bundlr-macos-x86_64`
- **macOS (Apple Silicon)**: `bundlr-macos-aarch64`
- **Windows**: `bundlr-windows-x86_64.exe`

After downloading:

**On Linux/macOS:**
```bash
# Make it executable
chmod +x bundlr-*

# Move it to your PATH (optional but recommended)
sudo mv bundlr-* /usr/local/bin/bundlr

# Or run it directly
./bundlr-* cowsay "Hello!"
```

**On Windows:**
```cmd
# Just run it from where you downloaded it, or
# Add the folder to your PATH for easier access
bundlr-windows-x86_64.exe cowsay "Hello!"
```

### Option 2: Build from Source

If you have [Zig](https://ziglang.org/) installed:

```bash
# Clone the repository
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr

# Build bundlr
zig build

# The binary will be in zig-out/bin/bundlr
```

## Quick Start Examples

Once installed, try these commands:

```bash
# ASCII art with cowsay
bundlr cowsay -t "Hello World"

# Make HTTP requests with httpie
bundlr httpie GET httpbin.org/json

# Get help for any tool
bundlr ty --help

# Run tools directly from GitHub
bundlr https://github.com/astral-sh/ruff --help
bundlr https://github.com/ai-mindset/distil serve --help
```

## How It Works

When you run a command with bundlr, it automatically:

1. **Downloads Python** - Gets Python 3.13 if you don't have it
2. **Creates an isolated environment** - No conflicts with your system
3. **Installs the package** - Uses pip for PyPI packages or uv for Git repos
4. **Runs your command** - Passes all your arguments through
5. **Cleans up** - Removes temporary files automatically

### Example Output

```
🚀 Bundlr: Bootstrapping cowsay v1.0.0 (Python 3.13)
📥 Ensuring Python 3.13 is available...
📦 Setting up virtual environment...
📋 Installing project package: cowsay
🎯 Executing application...
 _____________
< Hello World >
 -------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
✅ Application completed successfully
```

## Platform Support

- **Linux (x86_64)**: ✅ Fully supported and tested
- **macOS (Intel & Apple Silicon)**: ✅ Supported
- **Windows**: ✅ Supported

## Troubleshooting

**"Permission denied" error?**  
On Linux/macOS, make sure the file is executable: `chmod +x bundlr`

**Can't find bundlr after download?**  
Make sure it's in your PATH or run it with `./bundlr` (or full path on Windows)

**Python download fails?**  
Check your internet connection. bundlr needs to download Python the first time.

## For Maintainers: Creating Releases

To create a new release with automatically built binaries:

```bash
# Tag the release
git tag v1.0.0
git push origin v1.0.0
```

The GitHub Actions workflow will automatically:
- Build bundlr for all platforms (Linux, macOS Intel/ARM, Windows)
- Create a GitHub release with all binaries attached
- Generate release notes from commits

## License

MIT
