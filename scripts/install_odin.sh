#!/usr/bin/env bash
# Bootstrap the pinned compiler using only host tools; never install OS packages.
set -euo pipefail

bundlr_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundlr_destination="$bundlr_root/.build/odin-toolchain"
if [[ -e "$bundlr_destination" || -L "$bundlr_destination" ]]; then
  printf 'Refusing to replace %s\n' "$bundlr_destination" >&2
  exit 1
fi
bundlr_version=$(sed -n 's/^COMPILER_VERSION :: "\([^"]*\)"$/\1/p' "$bundlr_root/scripts/main.odin")
bundlr_revision=$(sed -n 's/^COMPILER_REVISION :: "\([^"]*\)"$/\1/p' "$bundlr_root/scripts/main.odin")
[[ -n "$bundlr_version" && ${#bundlr_revision} -eq 40 ]]
mkdir -p "$bundlr_root/.build"
bundlr_stage=$(mktemp -d "$bundlr_root/.build/odin-install-XXXXXX")
bundlr_reserved=false
bundlr_complete=false
trap 'rm -rf -- "$bundlr_stage"; if [[ "$bundlr_reserved" == true && "$bundlr_complete" == false ]]; then rm -rf -- "$bundlr_destination"; fi' EXIT

bundlr_name=odin
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)
    bundlr_archive=odin-linux-amd64-dev-2026-11a.tar.gz
    bundlr_sha=65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618 ;;
  Darwin/arm64)
    bundlr_archive=odin-macos-arm64-dev-2026-11a.tar.gz
    bundlr_sha=fa10eee280c8786758e3ff0b8fdd9355e1c9447b1f0b8c72764e25ee4ebc3e22 ;;
  MINGW*/*|MSYS*/*)
    bundlr_archive=odin-windows-amd64-dev-2026-11a.zip
    bundlr_sha=259effedf2997293c8fa4a5e497496f8ebce9f826652d9dd353a9dd2113c31fd
    bundlr_name=odin.exe ;;
  Darwin/x86_64)
    # This release has no Intel macOS binary. Build the exact compiler commit
    # with an existing LLVM 20; this is compiler bootstrap, not an app dependency.
    bundlr_llvm=${LLVM_CONFIG:-}
    if [[ -z "$bundlr_llvm" ]]; then bundlr_llvm=$(command -v llvm-config-20 || true); fi
    if [[ -z "$bundlr_llvm" && -x /usr/local/opt/llvm@20/bin/llvm-config ]]; then bundlr_llvm=/usr/local/opt/llvm@20/bin/llvm-config; fi
    if [[ -z "$bundlr_llvm" ]]; then printf 'Existing LLVM 20 is required to bootstrap Intel macOS Odin; set LLVM_CONFIG.\n' >&2; exit 1; fi
    [[ "$("$bundlr_llvm" --version)" == 20.* ]]
    git init "$bundlr_stage/source"
    git -C "$bundlr_stage/source" config core.abbrev 7
    git -C "$bundlr_stage/source" remote add origin https://github.com/odin-lang/Odin.git
    git -C "$bundlr_stage/source" fetch --depth 1 origin "$bundlr_revision"
    git -C "$bundlr_stage/source" checkout --detach FETCH_HEAD
    [[ "$(git -C "$bundlr_stage/source" rev-parse HEAD)" == "$bundlr_revision" ]]
    LLVM_CONFIG="$bundlr_llvm" make -C "$bundlr_stage/source" nightly
    bundlr_compiler="$bundlr_stage/source/odin" ;;
  *) printf 'Unsupported native builder host.\n' >&2; exit 1 ;;
esac

if [[ -n ${bundlr_archive:-} ]]; then
  bundlr_file="$bundlr_stage/$bundlr_archive"
  curl --fail --location --proto '=https' --proto-redir '=https' \
    "https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/$bundlr_archive" --output "$bundlr_file"
  if command -v sha256sum >/dev/null; then
    printf '%s  %s\n' "$bundlr_sha" "$bundlr_file" | sha256sum --check -
  else
    printf '%s  %s\n' "$bundlr_sha" "$bundlr_file" | shasum -a 256 --check -
  fi
  mkdir "$bundlr_stage/extracted"
  if [[ "$bundlr_name" == odin.exe ]]; then
    bundlr_windows=$(cygpath -u "${SYSTEMROOT:-${SystemRoot:-C:\Windows}}")
    "$bundlr_windows/System32/tar.exe" -xf "$bundlr_file" -C "$bundlr_stage/extracted"
  else
    tar -xzf "$bundlr_file" -C "$bundlr_stage/extracted"
  fi
  bundlr_compiler=$(find "$bundlr_stage/extracted" -type f -name "$bundlr_name")
fi
[[ -f "$bundlr_compiler" && "$bundlr_compiler" != *$'\n'* ]]
[[ "$("$bundlr_compiler" version)" == "$bundlr_version" ]]
# Reserve without replacement, then populate only the directory owned here.
mkdir "$bundlr_destination"
bundlr_reserved=true
cp -R -P "$(dirname -- "$bundlr_compiler")/." "$bundlr_destination/"
[[ "$("$bundlr_destination/$bundlr_name" version)" == "$bundlr_version" ]]
bundlr_complete=true
printf '%s\n' "$bundlr_destination"
