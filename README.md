# bundlr 📦

A Python application packaging tool written in Zig that creates standalone executables.

## What bundlr Does

bundlr packages Python applications into portable executables by:

1. **Downloading Python** - Fetches Python 3.13 from python-build-standalone on first run
2. **Creating Virtual Environment** - Sets up isolated environment for your app
3. **Installing Packages** - Uses pip to install your Python package from PyPI
4. **Executing Application** - Runs your app with forwarded command-line arguments

## Platform Support

**Current Status**: Functional on Linux with system dependencies

**System Requirements**:
- `curl` command available in PATH (for downloads)
- `tar` command available (for archive extraction)
- Internet connection on first run

**Platform-Specific Notes**:
- **Linux**: Fully tested and working
- **macOS**: Core functionality implemented, requires testing
- **Windows**: Core functionality implemented, requires testing and may need PowerShell

## Usage

Set environment variables and run:

```bash
# Required
export BUNDLR_PROJECT_NAME=cowsay

# Optional (with defaults)
export BUNDLR_PROJECT_VERSION=1.0.0    # Project version
export BUNDLR_PYTHON_VERSION=3.13      # Python version to use

# Build and run
zig build
./zig-out/bin/bundlr -- -t "Hello World"
```

**Example Output**:
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

## Current Limitations

- Requires system tools (`curl`, `tar`) to be available
- Downloads Python runtime on first execution (~122MB)
- Limited to packages available on PyPI
- No offline mode or embedded distributions yet

## License

MIT
