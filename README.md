# bundlr 📦

Run ANY Python package from PyPI or Git with zero setup!

## Quick Start

```bash
# Build bundlr
zig build

# Run PyPI packages
./zig-out/bin/bundlr cowsay -t "Hello World"
./zig-out/bin/bundlr httpie GET httpbin.org/json
./zig-out/bin/bundlr ty --help

# Run Git repositories
./zig-out/bin/bundlr https://github.com/astral-sh/ruff --help 
./zig-out/bin/bundlr https://github.com/ai-mindset/distil serve --help
```

## What bundlr Does

bundlr automatically handles everything:

✅ **Downloads Python 3.14** - Gets latest Python if needed  
✅ **Creates Virtual Environment** - Isolated environment for each app  
✅ **Installs Dependencies** - Uses pip (PyPI) or uv (Git) for fast installs  
✅ **Runs Your App** - Executes with your arguments  
✅ **Cleans Up** - Removes temporary files  

## Example Output

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

- **Linux**: ✅ Fully supported and tested
- **macOS**: ✅ Supported (x86_64, ARM64)
- **Windows**: ✅ Supported

## Releases

Pre-built binaries for all major platforms are automatically created with each release:

### Creating a Release

To create a new release, push a version tag:

```bash
# For new features (major version bump)
git tag v2.0.0
git push origin v2.0.0

# For bug fixes (patch version bump)
git tag v1.0.1
git push origin v1.0.1
```

The GitHub Actions workflow will automatically:
- Build bundlr for Linux, macOS (Intel & ARM), and Windows
- Create a GitHub release with all binaries attached
- Generate release notes automatically

### Downloading Releases

Visit the [Releases page](https://github.com/ai-mindset/bundlr/releases) to download pre-built binaries for your platform.

## License

MIT
