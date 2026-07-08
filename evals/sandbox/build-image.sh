#!/usr/bin/env bash
# Build the eval sandbox image (see Dockerfile next to this script) from a
# clean checkout of a pinned ref and push it to Vercel Container Registry,
# where `pnpm eval --sandbox` boots sandboxes from it.
#
#   evals/sandbox/build-image.sh [ref] [image-ref]
#
#   ref        git ref to bake (default: HEAD). The resolved sha is recorded
#              in the image at /opt/native-sdk/baked-ref.
#   image-ref  registry reference to push (default:
#              vcr.vercel.com/vercel-labs/zero-native/eval-sandbox:latest)
#
# Auth: log Docker in to the registry first, with either token:
#   printf '%s' "$VERCEL_OIDC_TOKEN" | docker login vcr.vercel.com --username oidc --password-stdin
#   printf '%s' "$VERCEL_TOKEN"      | docker login vcr.vercel.com --username "$VERCEL_TEAM_ID" --password-stdin
#
# Sandboxes only boot linux/amd64 images, so the build pins that platform
# (slow-but-fine under emulation on other hosts; the pre-warm layer runs the
# full test build once). After the push, the registry prepares an optimized
# image; Sandbox.create() returns image_not_ready until preparation finishes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
ref="${1:-HEAD}"
image="${2:-vcr.vercel.com/vercel-labs/zero-native/eval-sandbox:latest}"
sha="$(git -C "$repo_root" rev-parse "$ref")"

context="$(mktemp -d)"
trap 'rm -rf "$context"' EXIT
git -C "$repo_root" archive "$sha" | tar -x -C "$context"
# The image definition comes from the working tree, not the baked ref: the
# ref pins the SOURCES being baked; the Dockerfile you run is the one you
# are editing.
mkdir -p "$context/evals/sandbox"
cp "$here/Dockerfile" "$context/evals/sandbox/Dockerfile"

# LOAD=1 builds into the local Docker daemon instead of pushing — for
# validating Dockerfile changes before publishing.
if [ "${LOAD:-0}" = "1" ]; then
  output="type=docker,name=$image"
else
  output="type=image,name=$image,push=true,oci-mediatypes=true,compression=zstd,compression-level=3,force-compression=true"
fi

echo "baking $sha -> $image (${LOAD:+local load}${LOAD:-push})"
docker buildx build \
  --platform linux/amd64 \
  --build-arg "BAKED_REF=$sha" \
  -f "$context/evals/sandbox/Dockerfile" \
  --output "$output" \
  "$context"
