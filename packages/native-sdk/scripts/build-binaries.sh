#!/usr/bin/env bash
# Cross-compile the `native` CLI for every supported platform and stage
# the binaries where the release needs them:
#   - packages/native-sdk/npm/<platform>/bin/native[.exe]  (npm packages)
#   - zig-out/release/native-sdk-<platform>[.exe]          (GitHub release
#     assets, flat names + CHECKSUMS.txt)
#
# Zig cross-compiles all eight targets from any host; `zig build cli`
# builds only the CLI executable so the loop stays fast. Run from anywhere
# inside the repo. Pass a subset of npm platform keys to build fewer
# targets (e.g. `build-binaries.sh darwin-arm64`).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
npm_dir="$repo_root/packages/native-sdk/npm"
release_dir="$repo_root/zig-out/release"

# npm-platform-key  zig-target          release-asset-name
targets=(
  "darwin-arm64      aarch64-macos       native-sdk-darwin-arm64"
  "darwin-x64        x86_64-macos        native-sdk-darwin-x64"
  "linux-arm64-gnu   aarch64-linux-gnu   native-sdk-linux-arm64"
  "linux-x64-gnu     x86_64-linux-gnu    native-sdk-linux-x64"
  "linux-arm64-musl  aarch64-linux-musl  native-sdk-linux-musl-arm64"
  "linux-x64-musl    x86_64-linux-musl   native-sdk-linux-musl-x64"
  "win32-arm64       aarch64-windows     native-sdk-win32-arm64.exe"
  "win32-x64         x86_64-windows      native-sdk-win32-x64.exe"
)

selected=("$@")

want() {
  [ ${#selected[@]} -eq 0 ] && return 0
  local key="$1"
  for s in "${selected[@]}"; do
    [ "$s" = "$key" ] && return 0
  done
  return 1
}

mkdir -p "$release_dir"

built=0
for entry in "${targets[@]}"; do
  read -r key target asset <<<"$entry"
  want "$key" || continue

  ext=""
  case "$asset" in *.exe) ext=".exe" ;; esac

  prefix="$repo_root/zig-out/cli/$key"
  echo "==> $key ($target)"
  (cd "$repo_root" && zig build cli -Dtarget="$target" -Doptimize=ReleaseSmall --prefix "$prefix")

  built_binary="$prefix/bin/native$ext"
  [ -f "$built_binary" ] || { echo "error: expected $built_binary after build" >&2; exit 1; }

  mkdir -p "$npm_dir/$key/bin"
  cp "$built_binary" "$npm_dir/$key/bin/native$ext"
  chmod 755 "$npm_dir/$key/bin/native$ext"

  cp "$built_binary" "$release_dir/$asset"
  chmod 755 "$release_dir/$asset"
  built=$((built + 1))
done

if [ "$built" -eq 0 ]; then
  echo "error: no targets matched: $*" >&2
  exit 1
fi

(cd "$release_dir" && shasum -a 256 native-sdk-* > CHECKSUMS.txt)

echo
echo "Staged $built binaries:"
ls -lh "$release_dir" | awk 'NR>1 {printf "  %-36s %s\n", $NF, $5}'
