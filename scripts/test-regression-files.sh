#!/bin/sh
# Exercise the native harness verifier with the actual stale-index regression fixture.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/regression-file-checks"
mkdir -p "$OUT"
swiftc -parse-as-library "$ROOT/Packages/ChatComputerKit/Sources/Harness/RegressionFileValidation.swift" \
  "$ROOT/scripts/tests/fixtures/RegressionFilesProbe.swift" -o "$OUT/probe"
"$OUT/probe" "$ROOT/scripts/tests/fixtures/organize-stale-index.txt"
