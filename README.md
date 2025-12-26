# bundlr 📦

bundlr lets you instantly run Python command-line tools without installation hassles. Just type `bundlr` followed by the package name, and bundlr handles everything else automatically.

**Use case examples:**
- 🚀 Trying out Python CLI tools without installing them
- 🔧 Running tools from GitHub repositories
- 🧪 Testing different versions of packages
- ⚡ Quick one-off commands without setup

## Installation

### Option 1: Download Pre-Built Binary (Easiest!)

> **Note:** Pre-built binaries will be available on the [Releases page](https://github.com/ai-mindset/bundlr/releases) once the first version is released. Until then, please use Option 2 (build from source).

When releases are available, download the binary for your platform:

- **Linux**: `bundlr-linux-x86_64`
- **macOS (Intel)**: `bundlr-macos-x86_64`
- **macOS (Apple Silicon)**: `bundlr-macos-aarch64`
- **Windows**: `bundlr-windows-x86_64.exe`

After downloading:

**On Linux/macOS:**
```bash
# Replace with your actual downloaded filename
chmod +x bundlr-linux-x86_64 # Linux
# or 
chmod +x bundlr-macos-x86_64 # macOS

# Rename and move to PATH (recommended for easy access)
sudo mv bundlr-linux-x86_64 /usr/local/bin/bundlr
# or 
sudo mv bundlr-macos-x86_64 /usr/local/bin/bundlr

# Now you can run it from anywhere
bundlr cowsay -t "Hello!"
```

**On Windows:**
```cmd
REM Run directly with the full filename
bundlr-windows-x86_64.exe cowsay -t "Hello!"

REM Or rename it to bundlr.exe for easier use
rename bundlr-windows-x86_64.exe bundlr.exe
bundlr.exe cowsay -t "Hello!"
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

# Format Python code with black
bundlr black --help

# Run tools directly from GitHub (Python projects only)
bundlr https://github.com/psf/black --help
bundlr https://github.com/ai-mindset/distil --help
```

## How It Works

When you run a command with bundlr, it automatically:

1. **Downloads Python** - Gets Python 3.14 if you don't have it
2. **Creates an isolated environment** - No conflicts with your system
3. **Installs the package** - Uses pip for PyPI packages or uv for Git repos
4. **Runs your command** - Passes all your arguments through
5. **Cleans up** - Removes temporary files automatically

**Storage & Caching:**
bundlr caches downloads to avoid repeated work. Python distributions (~60MB), package managers, and virtual environments are stored in your system's cache directory (`~/.cache/bundlr` on Linux, `~/Library/Caches/bundlr` on macOS). The cache has a 1GB default limit with automatic cleanup.

### Example Output

```
🚀 Bundlr: Bootstrapping cowsay v1.0.0 (Python 3.14)
📥 Ensuring Python 3.14 is available...
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

## System Requirements

bundlr works out-of-the-box on most systems but requires:
- Internet connection (for downloading Python and packages)
- `tar` and `gzip` for archive extraction (pre-installed on most systems)
- `curl` or `wget` for downloads (pre-installed on most systems)

## Troubleshooting

**"Permission denied" error on Linux/macOS?**
Make sure the file is executable: `chmod +x bundlr-linux-x86_64` (use your actual filename)

**Command not found after installation?**
- If you moved it to `/usr/local/bin/bundlr`, make sure `/usr/local/bin` is in your PATH
- Or run it with the full path: `./bundlr-linux-x86_64` from the download directory
- On Windows, either use the full filename `bundlr-windows-x86_64.exe` or rename it to `bundlr.exe`

**Python download fails?**
Check your internet connection. bundlr needs to download Python (~60MB) the first time you use it.

**Package installation errors?**
- Try again - network issues can cause temporary failures
- Check if the package name is correct on PyPI or GitHub
- For GitHub repositories, ensure they contain a Python project with proper setup files

**Cache issues?**
Clear the cache directory manually if needed: `rm -rf ~/.cache/bundlr` (Linux) or `rm -rf ~/Library/Caches/bundlr` (macOS)

## Development

Want to contribute or run tests? You'll need [Zig](https://ziglang.org/) (minimum version 0.15.2):

```bash
# Run tests
zig build test

# Build and run
zig build run -- cowsay -t "Hello from dev!"

# Run comprehensive test suite
./test_all.sh
```

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
