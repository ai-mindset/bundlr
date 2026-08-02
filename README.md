# Bundlr

Bundlr turns a Python application from PyPI or HTTPS Git into a self-contained native application
that the recipient can run without installing Python, uv, Deno, or Bundlr.

Bundlr is a beta packaging tool. Generated applications must be tested on every target before they
are delivered to clients.

## Workflow

1. Open Bundlr.
2. Enter a pinned PyPI requirement or HTTPS Git URL.
3. Enter the application name and Python entry point.
4. Choose console or windowed mode.
5. Click **Package**.

The desktop application builds for its current platform. The CI workflow runs the same packaging
pipeline on native Linux x64, Windows x64, macOS ARM64, and macOS Intel workers.

The command-line equivalent is:

```sh
bundlr \
  --name "Example App" \
  --command example-app \
  --kind windowed \
  --python 3.12 \
  --target linux-x86_64 \
  --output dist \
  example-app==1.0.0
```

Git example:

```sh
bundlr \
  --name Black \
  --command black \
  --kind console \
  https://github.com/psf/black.git
```

Applications with dynamic imports or package data can use reviewed collection hints:

```sh
bundlr \
  --name Posting \
  --command posting \
  --kind console \
  --collect textual \
  --collect posting \
  https://github.com/darrenburns/posting.git@56703a11513e8e74e681b4f859f31945b71e746f
```

## How it works

Bundlr uses a checksum-verified, pinned [uv](https://docs.astral.sh/uv/) executable to obtain the
requested Python and create an isolated build environment. It inspects the package's standard
`console_scripts` and `gui_scripts` metadata, generates a static launcher, and freezes the
application with pinned [PyInstaller](https://pyinstaller.org/).

PyInstaller builds on the target operating system; it does not cross-compile applications. Bundlr
therefore builds locally for the current platform and uses native CI workers for the complete target
matrix.

The beta deliberately uses PyInstaller's `onedir` mode. It is more reliable than `onefile` because
the application does not unpack itself into a temporary directory on every launch. CI archives the
tested directory as ZIP on Windows and `tar.gz` on Linux and macOS.

## Verified beta status

- Strict TypeScript formatting, linting, type checking, and 34 unit tests pass.
- A pinned PyCowsay package builds and runs on Linux without an installed Python environment.
- The generated PyCowsay application is 35,059,154 bytes (33.44 MiB) unpacked.
- Posting builds from an immutable Git commit with reviewed `textual` and `posting` collection hints,
  starts under a minimal environment, and is 63,041,825 bytes (60.12 MiB) unpacked.
- CI defines native builds and generated-application smoke tests for all four supported targets.
- Generated client applications do not contain Bundlr, Deno, or uv.

Native CI has not yet run for this rewrite. Windows and macOS support must be considered unverified
until those jobs pass.

## Development

Requires Deno 2.9.4 or later.

```sh
deno task check
deno task test
deno task prepare:uv
```

Run Bundlr from source:

```sh
deno task start -- --kind console pycowsay==0.0.0.2
```

Build Bundlr's desktop application:

```sh
deno task build
```

## Current limitations

- Bundlr and generated applications are unsigned. Corporate application-control approval may still
  be required.
- The desktop UI builds only for its current platform. Remote submission of all-target builds is not
  implemented.
- Application name and entry point are not yet auto-detected in the desktop UI.
- Some Python applications require package-specific PyInstaller hooks, hidden imports, data files,
  or native libraries. Repeatable `--collect` hints are available for reviewed compatibility
  recipes.
- Generated size depends on the application. The 60 MB CI budget guards the small reference fixture;
  it is not a universal limit for dependency-heavy applications.
- Linux compatibility depends on the system libraries used by the native build worker.
- macOS application signing, notarisation, and Windows code signing are not implemented.
- `deno desktop` remains experimental.

## Security

Packaging installs and analyses third-party Python code. Use pinned, reviewed sources and trusted
build workers. Dependency isolation is not a security sandbox. Bundlr refuses to overwrite an
existing output artifact and executes subprocesses without a shell.

See [IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md) for corporate deployment and allow-listing details.
