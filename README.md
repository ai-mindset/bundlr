# Bundlr 📦

Bundlr turns a Python application from PyPI or HTTPS Git into a self-contained, double-clickable
application for Windows, macOS, and Linux. Recipients do not need Python, uv, Deno, or Bundlr.

## Package an application

Open Bundlr, paste a pinned package source, select the targets, and click **Package**. Bundlr
detects the application name, entry point, and console/GUI type when possible.

CLI examples:

```sh
bundlr --target all example-app==1.2.3

bundlr --target all \
  https://github.com/example/example-app.git@0123456789abcdef0123456789abcdef01234567
```

Use `--name`, `--command`, or `--kind` only when automatic detection is ambiguous.

Each target produces:

- A relocatable application directory with a double-click launcher.
- A client ZIP or `tar.gz` archive.
- SHA-256 checksums, dependency inventory, licence notices, and build metadata.

## How cross-target packaging works

Bundlr combines a checksum-pinned target
[Python runtime](https://github.com/astral-sh/python-build-standalone) with target-compatible wheels
selected by [uv](https://docs.astral.sh/uv/). It does not use PyInstaller or execute foreign target
binaries while packaging.

Supported applications are:

- Pure Python; or
- Dependent on native packages that publish wheels for every selected target.

Bundlr rejects missing target wheels and Git projects that build host-specific native code. This
prevents a Linux binary from being accidentally delivered in a Windows or macOS application.

## Prototype status

- One Linux command successfully generated Linux x64, Windows x64, macOS ARM64, and macOS Intel
  archives.
- The Linux application launched successfully; foreign executables and all archive checksums were
  verified structurally.
- The four client archives measured 23–33 MiB.
- Formatting, linting, type checking, and 35 tests pass.
- Native Windows and macOS launch testing remains required before client release.

Bundlr and generated applications are currently unsigned. Corporate controls, SmartScreen, or
Gatekeeper may require IT approval; use [IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md).

## Development

Requires Deno 2.9.4 or later.

```sh
deno task check
deno task test
deno task build
```

GitHub Actions publishes Bundlr releases. Client applications are built locally by Bundlr and do not
depend on CI.
