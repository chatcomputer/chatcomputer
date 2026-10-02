#!/bin/sh
# Builds cc-harness, signs it ad hoc with the virtualization entitlement, and runs it.
#   scripts/harness.sh live-loop             (needs CC_API_KEY; see Sources/Harness/main.swift)
#   scripts/harness.sh vm install | up … | status
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/ChatComputerKit"
swift build --package-path "$PKG" --product cc-harness >&2
BIN="$(swift build --package-path "$PKG" --show-bin-path)/cc-harness"
codesign --force --sign - --entitlements "$ROOT/scripts/harness.entitlements" "$BIN" >&2
# The app imports a bundle's harness-secrets.json into its Keychain and deletes it. Reading the app's
# Keychain items from here would show a Keychain prompt and block an unattended run, so instead launch
# the app once with CC_DEV_HARNESS_SECRETS=1, which writes the file back for the harness.
if [ -n "${CC_VM_BUNDLE:-}" ] && [ -f "$CC_VM_BUNDLE/spec.json" ] && [ ! -f "$CC_VM_BUNDLE/harness-secrets.json" ]; then
  echo "note: $CC_VM_BUNDLE has no harness-secrets.json; run the app once with CC_DEV_HARNESS_SECRETS=1" >&2
fi
exec "$BIN" "$@"
