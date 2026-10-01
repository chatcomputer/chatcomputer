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
exec "$BIN" "$@"
