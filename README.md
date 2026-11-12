# Bundlr 📦

Package a pinned Python application from PyPI or HTTPS Git into a self-contained
application for Linux x64, Windows x64, or macOS ARM64/x64. Recipients need neither
Python, Bun, uv nor Bundlr installed. Bundlr itself is one Bun-compiled executable
with its browser interface and verified uv payload embedded.

## Build from source

Requires Node.js/npm, Git and `tar`. Install the exact Bun distribution from
`.bun-version` below; `build-lock.json` verifies its native compiler revision.
This compiler is an experimental canary with `compile --trim`.

```sh
npm install --prefix .build/bun-toolchain --no-audit --no-fund "bun@$(tr -d '\r\n' < .bun-version)"
export PATH="$PWD/.build/bun-toolchain/node_modules/.bin:$PATH"
bun install --frozen-lockfile --ignore-scripts
bun run prepare:uv
bun run verify
bun test src
bun test --aot src
bun run build
bun run verify:compiled
```

On Linux the output is `dist/bundlr-linux-x86_64`, with a `.sha256` checksum and a
JSON build/size record. Native Windows and macOS builds use their corresponding
filenames. Existing outputs are never overwritten. For a rebuild, choose a new
path: `bun scripts/build.ts dist/bundlr-next`.

## Use

Run without arguments for the local browser interface, or use the CLI:

```sh
./dist/bundlr-linux-x86_64
./dist/bundlr-linux-x86_64 --help
./dist/bundlr-linux-x86_64 --diagnose
./dist/bundlr-linux-x86_64 --name Black --command black --kind console black==26.5.1
```

For a Windows desktop application built on Linux:

```sh
./dist/bundlr-linux-x86_64 --name PipUI --command pip-ui --kind windowed \
  --target windows-x86_64 pip-ui-tkinter==0.2.0
```

Use `--target all` for all four targets. HTTPS Git sources can end in `@revision`;
use a full commit for reproducible source selection. Dependencies must have wheels
for the chosen target; Git root wheels must be platform-independent.

Packages with several commands require `--command`. Black provides `black` and
`blackd`; in the browser, enter `black` under **Application entry point**.
**Cancel** stops the active build; **Quit Bundlr** stops the local server.

Outputs go to `dist/` unless `--output PATH` is supplied. Send the complete client
archive and its `.sha256` file. For the Linux example, verify before extracting:

```sh
(cd dist && sha256sum --check Black-linux-x86_64.tar.gz.sha256)
```

Applications include a manifest, dependency inventory, licence notices and
`SHA256SUMS`. Use [IT_SUPPORT_REPORT.md](IT_SUPPORT_REPORT.md) for support evidence.
Build on a controlled machine: Bundlr uses the builder's privileges and is not a
security sandbox. Python/package downloads need network access. `--diagnose`
verifies and repairs the embedded uv cache offline. `BUNDLR_CACHE_DIRECTORY` and
`BUNDLR_PYTHON_CACHE_DIRECTORY` select cache locations; an explicit
`BUNDLR_UV_EXECUTABLE` must match the pinned host checksum.

## Acceptance and release

```sh
bun run test:acceptance
bun run test:browser
```

The browser test requires Chrome/Chromium; set `BUNDLR_SMOKE_CHROME` if necessary.
For a user-installed Flatpak Brave:

```sh
BUNDLR_SMOKE_CHROME="$HOME/.local/share/flatpak/exports/bin/com.brave.Browser" bun run test:browser
```

CI checks Linux on ordinary changes. Manual full runs and version tags also check
native Windows/macOS builders and execute Linux-built recipients on those hosts.
Publishing requires every check, including real browser packaging, to pass.
