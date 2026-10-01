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
: "${APPLE_ID:?set APPLE_ID}" "${APPLE_SPECIFIC_PASSWORD:?set APPLE_SPECIFIC_PASSWORD}" "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"

rm -rf "$OUT" && mkdir -p "$OUT"
(cd "$ROOT" && xcodegen generate -q)

echo "== build (Developer ID, hardened runtime)"
xcodebuild -project "$ROOT/ChatComputer.xcodeproj" -scheme ChatComputer -configuration Release \
  -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | grep -E "error:|warning: .*sign|BUILD"
ditto "$DD/Build/Products/Release/ChatComputer.app" "$OUT/ChatComputer.app"
APP="$OUT/ChatComputer.app"

echo "== verify signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
for bundle in "$APP" "$APP/Contents/Resources/GuestAgent/ChatComputerAgent.app"; do
  codesign -dv "$bundle" 2>&1 | grep -E "^Authority=Developer ID Application|flags=.*runtime|Timestamp=" | sed "s|^|  $(basename "$bundle"): |"
done
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q com.apple.security.virtualization \
  && echo "  virtualization entitlement: present"

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
