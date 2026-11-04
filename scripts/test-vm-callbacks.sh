#!/bin/sh
# Exercise native delegate ownership without booting a VM or touching user data.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/scripts/tests/vm-callback-probe"
SCRATCH="$ROOT/build/vm-callback-probe"
swift build --package-path "$PACKAGE" --scratch-path "$SCRATCH"
BIN_DIR=$(swift build --package-path "$PACKAGE" --scratch-path "$SCRATCH" --show-bin-path)
codesign --force --sign - --entitlements "$PACKAGE/entitlements.plist" "$BIN_DIR/VMCallbackProbe"
"$BIN_DIR/VMCallbackProbe"
