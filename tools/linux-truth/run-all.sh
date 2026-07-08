#!/usr/bin/env bash
# Linux live-truth loop, end to end. Run from the repo root on the host:
#
#   tools/linux-truth/run-all.sh [image|up|sync|recon|drive|suites|all]
#
# What it does (container-side, repo mounted read-only at /src, all build
# output in the container-local /work volume):
#   image  - build the container image (Zig + GTK4 + WebKitGTK dev + Xvfb)
#   up     - start (or restart) the long-lived container and sync sources
#   sync   - rsync /src -> /work (run after local edits)
#   recon  - build every showcase app for Linux, launch under Xvfb, dump
#            snapshot/widgets/views + engine and X screenshots to /out
#   drive  - per-app interaction scenarios (clicks, text input, wheel
#            scrolling, resize incl. min-size probe) with screenshots
#   suites - engine suite, example suites, and the webview link check,
#            all on real Linux
#   all    - everything above, in order
#
# Artifacts land in the container's /out; copy them out with
#   docker cp native-sdk-linux-truth:/out <dest>
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
image=native-sdk-linux-truth
container=native-sdk-linux-truth
step="${1:-all}"

build_image() {
  docker build -t "$image" "$here"
}

up() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume create linux-truth-work >/dev/null
  docker run -d --name "$container" \
    -v "$repo_root":/src:ro \
    -v linux-truth-work:/work \
    "$image" sleep infinity >/dev/null
  docker exec "$container" mkdir -p /out
  sync_sources
}

sync_sources() {
  # A verdict from this loop is only as honest as the tree it ran on.
  # The long-lived container binds /src at CREATE time, so a container
  # started from one checkout (say, an agent worktree) keeps testing
  # THAT tree forever — a later invocation from a different checkout
  # would sync and pass against the wrong sources while looking green.
  # Refuse loudly instead of reporting another tree's truth.
  local mounted
  mounted="$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/src"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
  if [ -z "$mounted" ]; then
    echo "linux-truth: container '$container' is not running; start it with '$0 up'" >&2
    exit 1
  fi
  if [ "$mounted" != "$repo_root" ]; then
    echo "linux-truth: container '$container' mounts /src from" >&2
    echo "  $mounted" >&2
    echo "but this invocation is from" >&2
    echo "  $repo_root" >&2
    echo "so its results would describe a different tree. Recreate it with '$0 up'." >&2
    exit 1
  fi
  docker exec "$container" bash /src/tools/linux-truth/sync.sh
}

recon() {
  docker exec "$container" bash /src/tools/linux-truth/recon.sh
}

drive() {
  docker exec "$container" bash /src/tools/linux-truth/drive.sh
}

suites() {
  docker exec -w /work "$container" zig build test
  docker exec -w /work "$container" zig build validate
  docker exec -w /work "$container" zig build test-webview-system-link -Dplatform=linux
  docker exec -w /work "$container" zig build test-examples-native
}

case "$step" in
  image) build_image ;;
  up) up ;;
  sync) sync_sources ;;
  recon) sync_sources; recon ;;
  drive) sync_sources; drive ;;
  suites) sync_sources; suites ;;
  all) build_image; up; recon; drive; suites ;;
  *) echo "usage: $0 [image|up|sync|recon|drive|suites|all]" >&2; exit 2 ;;
esac
