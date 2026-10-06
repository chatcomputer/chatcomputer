#!/bin/sh
# After `gh release create vX.Y.Z`: points the Homebrew cask (chatcomputer/homebrew-tap) at the new release.
#
#   scripts/update-cask.sh 0.9.8
#
# Downloads the release's zip, checks it is the one in build/release when that exists, and pushes the new version
# and SHA-256 to Casks/chatcomputer.rb. Users then get it with `brew upgrade --cask chatcomputer`.
set -eu
VERSION="${1:?usage: scripts/update-cask.sh X.Y.Z}"
URL="https://github.com/chatcomputer/chatcomputer/releases/download/v$VERSION/ChatComputer.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/ChatComputer.zip" "$URL"
SHA="$(shasum -a 256 "$WORK/ChatComputer.zip" | cut -d' ' -f1)"
LOCAL="$(dirname "$0")/../build/release/ChatComputer.zip"
if [ -f "$LOCAL" ] && [ "$(shasum -a 256 "$LOCAL" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "The published zip differs from build/release/ChatComputer.zip; not updating the cask." >&2
  exit 1
fi

git clone -q https://github.com/chatcomputer/homebrew-tap "$WORK/tap"
CASK="$WORK/tap/Casks/chatcomputer.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
if git -C "$WORK/tap" diff --quiet; then echo "The cask already points at $VERSION."; exit 0; fi
git -C "$WORK/tap" commit -qam "Chat Computer $VERSION"
git -C "$WORK/tap" push -q origin main
echo "Cask updated to $VERSION ($SHA)."
