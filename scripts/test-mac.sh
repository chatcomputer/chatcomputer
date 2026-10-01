#!/bin/sh
# Everything that runs unattended on a Mac:
#   1. package unit tests
#   2. Xcode build of both apps (ad hoc signed) + entitlement check
#   3. host-side VM API probes (DiskImageKit stack, vmnet) — no guest needed
#   4. live model loop against a simulated desktop, if CC_API_KEY is set
#      (any Anthropic-compatible endpoint; defaults to DeepSeek, see Sources/Harness/main.swift)
# VM install/boot probes take an IPSW and tens of minutes; run them with scripts/harness.sh vm ….
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="${CC_DERIVED_DATA:-$ROOT/.build/DerivedData}"

echo "== 1. swift test"
swift test --package-path "$ROOT/Packages/ChatComputerKit" 2>&1 | grep -E "Test run with|✘|error:" 

echo "== 2. xcodebuild"
(cd "$ROOT" && xcodegen generate -q)
xcodebuild -project "$ROOT/ChatComputer.xcodeproj" -scheme ChatComputer -configuration Debug \
  -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- build 2>&1 | grep -E "error:|BUILD"
codesign -d --entitlements - --xml "$DD/Build/Products/Debug/ChatComputer.app" 2>/dev/null \
  | grep -q com.apple.security.virtualization && echo "virtualization entitlement: present"

echo "== 3. vm selftest"
"$ROOT/scripts/harness.sh" vm selftest 2>/dev/null

if [ -n "${CC_API_KEY:-}" ]; then
  echo "== 4. live loop"
  for scenario in notes approval injection; do
    "$ROOT/scripts/harness.sh" live-loop --scenario "$scenario" 2>/dev/null | grep -E "result after|^PASS|^FAIL" | tr '\n' ' '
    echo
  done
else
  echo "== 4. live loop skipped (CC_API_KEY not set)"
fi
