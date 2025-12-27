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

> **Note:** Pre-built binaries will be available on the [Releases page](https://github.com/ai-mindset/bundlr/releases) once the first version is released. Until then, please use Option 2 (build from source).

When releases are available, download the binary for your platform:

- **Linux**: `bundlr-linux-x86_64`
- **macOS (Intel)**: `bundlr-macos-x86_64`
- **macOS (Apple Silicon)**: `bundlr-macos-aarch64`
- **Windows**: `bundlr-windows-x86_64.exe`

**🔒 Security Note:** All binaries include SHA256 checksums and SLSA build provenance attestations. See [VERIFICATION.md](VERIFICATION.md) for instructions on verifying downloaded binaries.

After downloading:

**On Linux:**
```bash
# Download binary
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-linux-x86_64

# Verify checksum (recommended)
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-linux-x86_64.sha256
echo "$(cat bundlr-linux-x86_64.sha256)  bundlr-linux-x86_64" | shasum -a 256 -c -

# Make executable
chmod +x bundlr-linux-x86_64

# Rename and move to PATH (recommended for easy access)
sudo mv bundlr-linux-x86_64 /usr/local/bin/bundlr

# Now you can run it from anywhere
bundlr cowsay "Hello!"
```

**On macOS:**
```bash
# Download binary (replace with your architecture: x86_64 or aarch64)
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-macos-x86_64

# Verify checksum (recommended)
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-macos-x86_64.sha256
echo "$(cat bundlr-macos-x86_64.sha256)  bundlr-macos-x86_64" | shasum -a 256 -c -

# Make executable
chmod +x bundlr-macos-x86_64

# Rename and move to PATH (recommended for easy access)
sudo mv bundlr-macos-x86_64 /usr/local/bin/bundlr

# Now you can run it from anywhere
bundlr cowsay "Hello!"
```

**On Windows:**
```powershell
# Download binary
Invoke-WebRequest -Uri "https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-windows-x86_64.exe" -OutFile "bundlr-windows-x86_64.exe"

# Verify checksum (recommended)
Invoke-WebRequest -Uri "https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-windows-x86_64.exe.sha256" -OutFile "bundlr-windows-x86_64.exe.sha256"
$expected = Get-Content bundlr-windows-x86_64.exe.sha256
$actual = (Get-FileHash bundlr-windows-x86_64.exe -Algorithm SHA256).Hash.ToLower()
if ($expected -eq $actual) { Write-Host "✓ Checksum verified!" -ForegroundColor Green } else { Write-Host "✗ Checksum mismatch!" -ForegroundColor Red }

# Run directly or rename
bundlr-windows-x86_64.exe cowsay "Hello!"
# Or rename: rename bundlr-windows-x86_64.exe bundlr.exe
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

1. **Downloads Python** - Gets Python 3.13 if you don't have it
2. **Creates an isolated environment** - No conflicts with your system
3. **Installs the package** - Uses pip for PyPI packages or uv for Git repos
4. **Runs your command** - Passes all your arguments through
5. **Cleans up** - Removes temporary files automatically

### Example Output

```
🚀 Bundlr: Bootstrapping cowsay v1.0.0 (Python 3.13)
📥 Ensuring Python 3.13 is available...
>>>>>>> a22e303 (Implement complete bundlr functionality)
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

<<<<<<< HEAD
- **Linux**: ✅ Fully supported and tested
- **macOS**: ✅ Supported (x86_64, ARM64)
- **Windows**: ✅ Supported
=======
- **Linux (x86_64)**: ✅ Fully supported and tested
- **macOS (Intel & Apple Silicon)**: ✅ Supported
- **Windows**: ✅ Supported

## Troubleshooting

**"Permission denied" error on Linux/macOS?**  
Make sure the file is executable: `chmod +x bundlr-linux-x86_64` (use your actual filename)

**Command not found after installation?**  
- If you moved it to `/usr/local/bin/bundlr`, make sure `/usr/local/bin` is in your PATH
- Or run it with the full path: `./bundlr-linux-x86_64` from the download directory
- On Windows, either use the full filename `bundlr-windows-x86_64.exe` or rename it to `bundlr.exe`

**Python download fails?**  
Check your internet connection. bundlr needs to download Python (~60MB) the first time you use it.

## For Maintainers: Creating Releases

To create a new release with automatically built binaries:

```bash
# Tag the release
git tag v1.0.0
git push origin v1.0.0
```

The GitHub Actions workflow will automatically:
- Build bundlr for all platforms (Linux, macOS Intel/ARM, Windows)
- Generate SHA256 checksums for each binary
- Create SLSA build provenance attestations
- Create a GitHub release with all binaries, checksums, and verification instructions attached
- Generate release notes from commits

### Verifying Release Integrity

After a release is created, verify it worked correctly:

```bash
# Download and verify a binary
gh attestation verify bundlr-linux-x86_64 --repo ai-mindset/bundlr

# Or verify checksums
curl -LO https://github.com/ai-mindset/bundlr/releases/download/v1.0.0/SHA256SUMS
curl -LO https://github.com/ai-mindset/bundlr/releases/download/v1.0.0/bundlr-linux-x86_64
shasum -a 256 -c SHA256SUMS --ignore-missing
```

See [VERIFICATION.md](VERIFICATION.md) for complete verification instructions.

## License

MIT
