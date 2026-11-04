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
. "$ROOT/scripts/check-output.sh"
LOGS="${CC_TEST_LOG_DIR:-$ROOT/build/test-logs}"

echo "== 1. swift test"
run_checked "$LOGS/unit.log" 'Test run with|✘|error:' swift test --package-path "$ROOT/Packages/ChatComputerKit"

echo "== 2. xcodebuild"
(cd "$ROOT" && xcodegen generate -q)
run_checked "$LOGS/build.log" 'error:|BUILD' xcodebuild -project "$ROOT/ChatComputer.xcodeproj" -scheme ChatComputer -configuration Debug \
  -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- build
codesign -d --entitlements - --xml "$DD/Build/Products/Debug/ChatComputer.app" >"$LOGS/entitlements.xml" 2>"$LOGS/codesign.log"
grep -q com.apple.security.virtualization "$LOGS/entitlements.xml" || { echo "FAIL: virtualization entitlement missing"; exit 1; }
echo "virtualization entitlement: present"

echo "== 3. vm selftest"
run_checked "$LOGS/selftest.log" '.' "$ROOT/scripts/harness.sh" vm selftest

if [ -n "${CC_API_KEY:-}" ]; then
  echo "== 4. live loop"
  for scenario in notes approval injection; do
    run_checked "$LOGS/live-$scenario.log" 'result after|^PASS|^FAIL' "$ROOT/scripts/harness.sh" live-loop --scenario "$scenario"
  done
else
  echo "== 4. live loop skipped (CC_API_KEY not set)"
fi
