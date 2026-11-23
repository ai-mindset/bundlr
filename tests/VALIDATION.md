# Odin rewrite validation — 2026-11-23

This checkout is not release-certified. Native Linux checks pass; real packaging,
Chrome workflows, native Windows/macOS execution and actual Actions evidence are
still required.

## Native tooling

The application, developer driver, filesystem/process integration, independent
ZIP reader, recipient checks and Chrome/CDP driver are Odin. The former package
manifest, runtime/dependency lockfiles, transpiler configuration/declarations,
application/harness scripts and unused archive-library vendor tree are removed.
There is no package installation or host scripting-runtime prerequisite.

The optional compiler bootstrap uses platform shell tools and verifies pinned
archive hashes and the exact compiler revision. A matching installed Odin does
not need bootstrap. Git, tar and platform libraries remain builder prerequisites;
Linux links system libcurl.so.4. Intel macOS compiler bootstrap requires an
existing LLVM 20 because the pinned release has no Intel macOS binary.

Python launcher and deterministic Git application/backend text are emitted by
Odin as packaged application content. Interpreter/resolver regressions run only
with the downloaded, checksum-verified bundled Python. Browser JavaScript remains
embedded UI content. Client partial-frame cancellation/retry regressions execute
inside real Chrome; there is no separate JavaScript runtime.

## Browser smoke HTTP response framing

The reported browser job timed out with an unqualified loopback error. The
smoke HTTP client waited for EOF even after receiving a complete Content-Length
body. Chromium's [DevTools JSON handler](https://github.com/chromium/chromium/blob/main/content/browser/devtools/devtools_http_handler.cc)
uses its [HTTP server](https://github.com/chromium/chromium/blob/main/net/server/http_server.cc),
which sends length-delimited responses without automatically closing the socket.
Waiting for closure can therefore time out on /json/list after its body arrived.

The reader now completes when the declared byte count arrives, including empty
bodies and responses split across reads. Responses without Content-Length still
require EOF; truncated or malformed framing fails. Existing timeouts and response
size bounds remain. HTTP failures identify their method/host/path; debugging
failures identify the WebSocket handshake or CDP method.

A deterministic reader fixture reproduced the old timeout for a complete UTF-8
body followed by Would_Block instead of EOF. It now passes for both single-byte
fragments and a single read. Additional regressions cover EOF-delimited bodies,
204/304 responses, truncation, malformed/duplicate lengths and unsupported transfer
encoding. The protocol suite now has five procedures, bringing the total to 20
with source and driver units. These are transport/framing unit checks, not a real
browser run: the local sandbox still blocks loopback and Flatpak Chromium.
The actual browser workflow requires a CI rerun.

## Compiler bootstrap banner regression

The reported CI failure occurred after successful archive checksum verification.
Odin's [pinned version command](https://github.com/odin-lang/Odin/blob/9a6991685ddf663956d9836602eb421e141fc443/src/main.cpp#L4056)
starts its banner with argv[0]. The installer invoked an absolute path but
expected the literal command name `odin`, rejecting the correct compiler.
The native driver's ODIN override had the same defect.

Both guards now ignore the executable label while comparing the complete pinned
version. Compiler dates, revision and archive hashes remain unchanged.
Installer failures report expected/received banners or an execution/layout error.
One driver regression procedure covers absolute paths with spaces, Windows .exe
names/CRLF and platform path spelling, and rejection of wrong dates, revisions,
missing executable labels and extra output. It runs in both debug and optimized
verification.

The full native check suite passes with ODIN set to the real compiler's absolute
path. An offline installer fixture containing that compiler and its standard
library reproduces the old failure after a valid fixture checksum, then completes
the fixed pre-copy/post-copy checks in paths with spaces. It also confirms that
occupied installations are preserved and wrong revisions fail with diagnostics
before publication. Only the fixture archive digest is substituted in owned test
copies; production archive pins and downloads are unchanged. Actual Actions
execution and native installer validation on other hosts remain pending.

## Candidate and pins

- Executable: `.build/theme-review/bundlr-linux-x86_64`.
- Compiler: `odin version dev-2026-11-nightly:9a69916`.
- Compiler commit: `9a6991685ddf663956d9836602eb421e141fc443`.
- Compiler pins: `scripts/main.odin`; acceptance pins: `tests/recipient.odin`.
- Flags: `-o:speed -vet -strict-style`, with bounds checks enabled.
- Complete executable: **17,754,544 bytes (16.932053 MiB)**, including browser UI
  and **16,792,733 compressed uv bytes**.
- SHA-256: `62f9b1cabd2cdfb0605bb35568d44fe9ac96f80473dcf79bd34db0cb7777f1e5`.
- JSON build record and `.sha256` sidecars are beside the executable.
- uv: **0.13.9**; CPython: **3.12.13**; Black acceptance: **26.5.1**.
- uv checksum-manifest SHA-256:
  `5679a011d4663f7d394463bbe057de440047424c09b84ff21fc1a2c5104f1a8c`.
- Prepared Linux uv executable SHA-256:
  `b73acdf73b96c3ac9e56d2fa933427b3ee6a901e3cce6ba1e3ecb3f91ca0d86a`.

The user successfully prepared uv and reported working Black packaging earlier.
That evidence does not certify the migrated acceptance harness or this exact
candidate. The native offline preparation command verifies the current prepared
payload and provenance against the source pins.

## Dark and light UI

Dark mode is explicit in the initial HTML/CSS, independently of the OS setting.
The labelled, keyboard-operable toggle exposes aria-pressed and remembers a
choice for the current origin when storage is available. Preference restoration
runs before styles are applied, under the existing session CSP nonce. Storage
errors preserve the default and do not prevent packaging.

Both palettes cover main/muted/placeholder text, input/select borders, primary
and cancel buttons, hover/disabled states and output/error streams. Focus has a
three-pixel outline; disabled buttons retain readable text. Narrow layouts stack
columns, and the output pane is keyboard-focusable for scrolling.

The explicit palette pairs were checked using the WCAG relative-luminance
formula against [text contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
and [control contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)
thresholds. The lowest measured ratios are:

| Palette | Text, including placeholders/disabled/logs | Control borders | Focus against page/field/log |
| --- | --- | --- | --- |
| Dark | 6.97:1 | 4.04:1 | 9.55:1 |
| Light | 6.15:1 | 3.21:1 | 6.41:1 |

Both embedded scripts pass syntax parsing. All 14 source, five protocol and one
driver unit procedures pass in debug and optimized builds; the executable builds and
passes compiled integrity. Real-browser checks now inspect computed contrast,
native control schemes, wide/narrow overflow, Space-key toggling, visible focus,
accessible toggle state and stored preference, including with a light OS scheme.
Those rendered checks remain unrun: the attempted smoke test fails to bind
loopback with Insufficient_Permissions. Installed Flatpak Chromium also cannot
connect/start in this sandbox, and its standalone binary requires a newer glibc.
Palette calculations and source checks do not establish rendered accessibility.

## Passed locally

| Check | Current evidence |
| --- | --- |
| Odin source units | 14 procedures in debug and optimized builds |
| Harness protocol units | Five procedures in debug and optimized builds; WebSocket handshake/masking/frame guards, incremental HTTP framing/transport and CDP evaluation parameter encoding |
| Driver units | One procedure in debug and optimized builds; invocation-path banners accepted and mismatched compiler versions rejected |
| Clean bootstrap | Copies only Odin source and the embedded UI into an owned clean tree, then builds the driver without prepared uv or scripting toolchains |
| Native integration | 13 filesystem/process/layout/build cases, plus saturated stdout and stderr cancellation on Linux |
| Compiled integrity | Passed against the retained executable with builder tools absent from PATH |
| Cross-target source checks | Native developer driver and imported application/tests checked for Windows x64, macOS ARM64 and macOS x64 with vet and strict style |
| Compiler bootstrap script | Bash syntax and offline real-compiler installation fixture passed; pre/post-copy guards, occupied-destination refusal and wrong-revision diagnostics checked |
| Workflow | YAML parsed and shell blocks syntax checked; all four jobs and release dependencies retained |
| Repository cleanup | Source/configuration scan and diff checks; no package manifests, scripting drivers, transpiler configuration or obsolete language source files |

The 13 integration cases cover literal subprocess arguments/nonzero exits/missing
executables; complete simultaneous 1 MiB stdout/stderr; cancellation and descendant
termination; independent ZIP decoding, CRCs, UTF-8 and executable modes; classic
ZIP size limits; publication and concurrent collision preservation; pre-download
collisions; checksum-before-extraction; HTTPS-only downloads; all four target
layouts/evidence/appended launcher ZIPs; ambiguous entry points; and executable,
sidecar and dangling-symlink build collisions. Saturated-console checks preserve
inherited pipe flags and reap descendants without waiting for output consumers.

Compiled checks cover invalid CLI input before output, version/help, offline uv
extraction, corrupt cache repair, permission/symlink repair, unverified overrides,
execution of the exact file whose checksum was checked, and modified embedded
payload rejection. The native path regression also covers missing outputs and
dangling symlinks without filesystem-dependent absolute-path resolution.

A focused protocol check exposed the pinned encoder's rejection of an `any` field
inside a struct. The driver now encodes CDP parameters separately, with a passing
regression for evaluation flags and escaped expressions. JavaScript template
content is inserted without passing its braces through Odin's format parser.

## Required gates not passed here

Native packaging was attempted before the theme update. It reached the
actual CPython download and failed with:

```text
HTTPS download failed: Couldn't resolve host name
```

Consequently the migrated real resolver, dependency-cycle/identity/marker,
source-build-prohibition, relocated-launcher and recipient checks have not run
with a verified bundled interpreter here. They remain mandatory in acceptance;
the standalone `managed` command has the same verified-download requirement.
Earlier checks using the removed harness are historical evidence only.

Browser acceptance against the new candidate stops at the sandbox's loopback
permission boundary. Installed Flatpak Chromium is also unusable here. Set
`BUNDLR_SMOKE_CHROME` to a usable installed executable on a Linux host that permits
loopback. Protocol units and source inspection do not establish rendered browser
or real socket behavior.

Windows/macOS source checks do not validate native process APIs, archives,
pythonw/Tk, unsigned-device behavior or the compiler bootstrap on those hosts.
Actual native jobs, Linux-built recipients on each target host, real Chrome
acceptance and Actions execution remain pending. No actionlint is installed.

## Commands and release gates

Run from the repository root using the pinned Odin compiler:

```sh
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- prepare-uv --prepared
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- check
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- verify .build/theme-review/bundlr-linux-x86_64
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- acceptance .build/theme-review/bundlr-linux-x86_64
odin run scripts -vet -strict-style -define:BUNDLR_EMBED_UV=false -- browser .build/theme-review/bundlr-linux-x86_64
```

`check` removes only its owned working directory. For another retained build use
`build NEW_PATH`; the executable and both sidecars must be absent. For retained
cross-target packaging use `acceptance BINARY NEW_DIRECTORY --all-targets`.
On native recipient hosts use `consume ARCHIVE_DIRECTORY`.

Ordinary branch/PR CI requires source/harness units, native integration, Linux
build/integrity, real packaging/recipients and real browser workflows. Full manual
runs and version tags also require all native hosts and Linux-built recipients
executed on those hosts. Manual full runs do not publish. Tagged runs stamp
src/common.odin through the native driver and publish only after every target
job, four executable checksums and licence assets pass. No gate was removed to
accommodate unavailable local boundaries.
