#!/usr/bin/env bash
#
# Fetches the prebuilt Libbox.xcframework (~480 MB, git-ignored) from a GitHub
# Release asset so CI can link against it without committing the binary.
#
# The framework is built from sing-box v1.13.5 via `make lib_apple` (sagernet/
# gomobile fork) — see the libbox-build reference. We host the zipped result as a
# release asset because the binary is too large for git and identical across PRs.
#
# Idempotent: if Frameworks/Libbox.xcframework already exists (a local dev box
# that built it), the download is skipped. Resolves TD-LIBBOX-FETCH / TEST-IOS-CI.
#
# Auth: uses `gh`. In CI set GH_TOKEN=${{ secrets.GITHUB_TOKEN }} (the workflow
# does). Override the source with LIBBOX_REPO / LIBBOX_TAG if it ever moves.
set -euo pipefail

REPO="${LIBBOX_REPO:-molkex/chameleon}"
TAG="${LIBBOX_TAG:-libbox-v1.13.5}"
ASSET="Libbox.xcframework.zip"
DEST="Frameworks"
FRAMEWORK="$DEST/Libbox.xcframework"

# Run from clients/apple regardless of where we're invoked.
cd "$(dirname "$0")/.."

if [ -d "$FRAMEWORK" ] && [ -n "$(ls -A "$FRAMEWORK" 2>/dev/null)" ]; then
  echo "fetch-libbox: $FRAMEWORK already present — skipping download."
  exit 0
fi

command -v gh  >/dev/null || { echo "fetch-libbox: gh CLI not found" >&2; exit 1; }
command -v ditto >/dev/null || { echo "fetch-libbox: ditto not found (macOS only)" >&2; exit 1; }

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "fetch-libbox: downloading $ASSET from $REPO@$TAG ..."
gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$tmp"

# ditto preserves the macOS framework symlink layout (Versions/Current → A).
# A plain unzip can flatten it and break codesign (see TD-LIBBOX-MAC-STRUCT).
echo "fetch-libbox: extracting ..."
ditto -x -k "$tmp/$ASSET" "$DEST"

if [ ! -d "$FRAMEWORK" ]; then
  echo "fetch-libbox: ERROR — $FRAMEWORK missing after extract" >&2
  exit 1
fi
echo "fetch-libbox: Libbox.xcframework ready."
