#!/bin/sh
# Builds ChatComputer.app (with the embedded guest agent) signed with Developer ID,
# notarizes it, staples the ticket and verifies it with Gatekeeper.
#
#   APPLE_ID=… APPLE_SPECIFIC_PASSWORD=… APPLE_TEAM_ID=… scripts/release.sh
#
# Output: build/release/ChatComputer.app and build/release/ChatComputer.zip
# The guest agent's TCC grants are bound to its signature, so release builds must always
# be signed with the same Developer ID (proposal §03).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DD="$ROOT/build/DerivedData-release"
. "$ROOT/scripts/check-output.sh"
: "${APPLE_ID:?set APPLE_ID}" "${APPLE_SPECIFIC_PASSWORD:?set APPLE_SPECIFIC_PASSWORD}" "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"

rm -rf "$OUT" && mkdir -p "$OUT"
(cd "$ROOT" && xcodegen generate -q)

echo "== build (Developer ID, hardened runtime)"
run_checked "$OUT/build.log" 'error:|warning: .*sign|BUILD' xcodebuild -project "$ROOT/ChatComputer.xcodeproj" -scheme ChatComputer -configuration Release \
  -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build
ditto "$DD/Build/Products/Release/ChatComputer.app" "$OUT/ChatComputer.app"
APP="$OUT/ChatComputer.app"

echo "== verify signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
for bundle in "$APP" "$APP/Contents/Resources/GuestAgent/ChatComputerAgent.app"; do
  signature_log="$OUT/$(basename "$bundle").signature.log"
  run_checked "$signature_log" '^Authority=Developer ID Application|TeamIdentifier=|flags=.*runtime|Timestamp=' codesign -d --verbose=4 "$bundle"
  grep -q '^Authority=Developer ID Application' "$signature_log" || { echo "Developer ID signature missing"; exit 1; }
  grep -qx "TeamIdentifier=$APPLE_TEAM_ID" "$signature_log" || { echo "Signing team mismatch"; exit 1; }
  grep -q 'flags=.*runtime' "$signature_log" || { echo "Hardened runtime missing"; exit 1; }
  grep -q '^Timestamp=' "$signature_log" || { echo "Secure signing timestamp missing"; exit 1; }
done
codesign -d --entitlements - --xml "$APP" >"$OUT/entitlements.xml" 2>"$OUT/codesign.log"
grep -q com.apple.security.virtualization "$OUT/entitlements.xml" || { echo "virtualization entitlement missing"; exit 1; }
echo "  virtualization entitlement: present"
# macOS 26 guests list the agent in Privacy settings only if Launch Services lets it run there: both its
# Info.plist and its binary must say 26 (project.yml, the agent's MACOSX_DEPLOYMENT_TARGET).
AGENT="$APP/Contents/Resources/GuestAgent/ChatComputerAgent.app"
MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$AGENT/Contents/Info.plist")
vtool -show-build "$AGENT/Contents/MacOS/ChatComputerAgent" >"$OUT/agent-build.txt"
MINOS=$(awk '/minos/ { print $2; exit }' "$OUT/agent-build.txt")
[ "$MIN" = "26.0" ] && [ "$MINOS" = "26.0" ] || { echo "  agent minimum macOS is $MIN (binary $MINOS), not 26.0"; exit 1; }
echo "  agent runs on macOS $MIN and later"

echo "== notarize"
ditto -c -k --keepParent "$APP" "$OUT/ChatComputer.zip"
xcrun notarytool submit "$OUT/ChatComputer.zip" --apple-id "$APPLE_ID" --password "$APPLE_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" --wait --output-format json > "$OUT/notary.json"
STATUS=$(/usr/bin/python3 -c "import json;print(json.load(open('$OUT/notary.json'))['status'])")
ID=$(/usr/bin/python3 -c "import json;print(json.load(open('$OUT/notary.json'))['id'])")
echo "  submission $ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$ID" --apple-id "$APPLE_ID" --password "$APPLE_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
  exit 1
fi

echo "== staple and assess"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Re-zip so the distributed archive carries the stapled ticket.
rm -f "$OUT/ChatComputer.zip" && ditto -c -k --keepParent "$APP" "$OUT/ChatComputer.zip"
echo "done: $OUT/ChatComputer.zip"
