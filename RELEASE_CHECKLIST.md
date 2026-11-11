# Bun release readiness

The main working tree is now the Bun implementation. Jac/Ende source, native FFI,
compiler patches, triplets, runtime manifests and workflow helpers have been
removed. Their Git history remains intact. No commit, push, tag or release has
been made by the agent.

## Local evidence

- [x] Tested compiler identified in `build-lock.json`.
- [x] Source validation, portable-wheel rules and artifact collision guards retained.
- [x] CLI and browser share one packaging state machine.
- [x] Browser authentication, cancellation/concurrency and cleanup-before-quit tests.
- [x] Literal launcher arguments, subprocess output flushing and descendant cancellation tests.
- [x] Final toolchain, type and formatting checks pass (48 typed files, 53 formatted files).
- [x] Source and AOT suites each pass 56 tests across 15 files.
- [x] Module consolidation reduces TypeScript files from 57 to 49 and application
  modules from 26 to 21. Moved function bodies and test assertions match the staged
  baseline exactly; only imports, file boundaries and unused tooling changed.
- [x] Final compiled diagnostic, fresh-cache extraction, corruption/permission repair,
  invalid-override rejection, symlink repair and embedded-payload tamper rejection pass.

The preserved Linux candidate predates module consolidation and is
**85,522,568 bytes (81.56 MiB)**,
including **23,619,574 bytes** of compressed uv. Its size is
within the accepted range; the former 50 MiB ceiling does not apply. The executable's
JSON and checksum record its exact compiler, flags, SHA-256 and size.
Rebuild the current sources to a new output path before final integration checks.
The temporary consolidation build passed compiled integrity checks and was removed.

## Required before release

- [ ] Real pinned Black and deterministic HTTPS Git packaging pass on Linux.
- [ ] Repeat real Chromium acceptance after module consolidation: source validation,
  streaming output, cancellation, concurrency, packaging/recipient execution and quit.
  The previous candidate passed on the host.
- [ ] Native Windows builder passes, including pythonw/Tk GUI and descendant cancellation.
- [ ] Native macOS ARM64 and Intel builders pass.
- [ ] Linux cross-built Black and Git recipients execute on Windows and both macOS hosts.
- [ ] Check manifests, dependency markers, licences, file modes and archive checksums.
- [ ] Review unsigned executable behaviour on a representative recipient device.
- [ ] Full manual CI run on the committed `bun` branch passes.
- [ ] Choose the release version and push its tag only after reviewing all evidence.

Source/unit tests do not certify these integration checks. Local DNS, loopback
and browser restrictions must be reported as blocks, never replaced by skipped
checks or mocks. The workflow fails rather than publishing when a gate fails.
The canary download moves: a revision mismatch stops the build until the updated
compiler is explicitly tested and pinned. Prefer a stable AOT release when one is
available.

## Commands

From the repository root:

```sh
export PATH="$HOME/.bun/bin:$PATH"
bun run verify
bun test src
bun test --aot src
bun run verify:compiled
bun run test:acceptance
bun run test:browser
```

Acceptance creates and cleans its own temporary output. To retain evidence and
exercise all target archives on Linux, provide a new directory:

```sh
bun scripts/acceptance.ts dist/bundlr-linux-x86_64 .build/acceptance-review --all-targets
```

On the other hosts, `scripts/consume.ts` validates and launches the matching
Linux-built archives. CI transfers them automatically. Its four host builds are
run only for full manual runs and tags, keeping ordinary checks cheaper.

After review and commit, the first push should use `git push -u origin bun` to
replace the branch's inherited `origin/rewrite/jac` tracking relationship. A
manual full run can then be started without publishing:

```sh
gh workflow run release.yml --ref bun
```

Keep version/tag publication separate until every required check passes.

## Recovery and cleanup

A small `.build/pre-bun-worktree.tar.gz` archive preserves the earlier uncommitted
files. It is a recovery copy, not a runtime/build dependency. Remove it only when
that recovery path is no longer needed. Generated staging and test directories
are cleaned by their owners. Do not remove a user-supplied acceptance evidence
directory during cleanup.

## Current environment blocks

`bun run test:acceptance` reaches the real Python download and fails with
`getaddrinfo ENOTFOUND github.com` in this sandbox. Native Chrome auto-discovery
is empty in this sandbox; the installed Flatpak
Ungoogled Chromium launcher was found and documented. The user ran the browser
suite on the host before module consolidation and reported: "Real browser
validation, streaming, packaging, cancellation, concurrency, shutdown and
recipient execution passed." Local
loopback binding remains prohibited here: the fresh consolidation build fails
with `EPERM: operation not permitted, listen`. Its CLI acceptance still fails at
the Python download with `ENOTFOUND github.com`. CLI/Git acceptance, the final
browser rerun and other-host checks remain pending on the host/CI. Workflow YAML
parses, but actionlint and actual GitHub Actions execution were unavailable locally.
