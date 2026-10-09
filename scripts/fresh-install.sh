#!/bin/sh
# Fresh-install test (STATUS.md 1.0, item 4): installs a release zip as a new user would, on this Mac.
#
#   scripts/fresh-install.sh build/release/ChatComputer.zip [deepseek:openAI:deepseek-flash]
#   CC_GUEST_MACOS=26 scripts/fresh-install.sh …   installs macOS 26 instead of 27
#   CC_RESTORE_IMAGE=path.ipsw scripts/fresh-install.sh …   installs from a local restore image (no download)
#
# 1. Copies the zip with a quarantine flag (as a browser download has), unzips it and checks Gatekeeper.
# 2. Moves your Chat Computer data folder (~/.chatcomputer, or the one chosen in setup) and preferences aside.
# 3. Launches with CC_AUTO_ONBOARD=1: downloads macOS (~26 GB), installs it, creates the account, installs the agent,
#    grants its permissions and saves the starting point. Times each step from the VM's spec.json.
# 4. Relaunches with your stored API key and a model, and runs one task end to end.
# 5. Deletes the new virtual Mac and puts your data and preferences back, whatever happened.
# Output: a log in /tmp/chatcomputer-fresh-install-<time>/ with screenshots of the window on failure.
set -eu
ZIP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
MODEL="${2:-deepseek:openAI:deepseek-flash}"
DOMAIN=app.chatcomputer.ChatComputer
# Your data folder, put back at the end; the new install uses the default folder.
SUPPORT="$(defaults read "$DOMAIN" DataDirectory 2>/dev/null || echo "$HOME/.chatcomputer")"
BACKUP="$SUPPORT.fresh-install-backup"
NEW="$HOME/.chatcomputer"
WORK="/tmp/chatcomputer-fresh-install-$(date +%Y%m%d-%H%M%S)"
LOG="$WORK/log.txt"
mkdir -p "$WORK"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

[ -e "$BACKUP" ] && { echo "A backup from an earlier run is still at $BACKUP. Put it back first."; exit 1; }
[ "$SUPPORT" != "$NEW" ] && [ -e "$NEW" ] && { echo "$NEW exists but isn't your data folder ($SUPPORT). Move it first."; exit 1; }
pgrep -f "ChatComputer.app/Contents/MacOS/ChatComputer" >/dev/null && { echo "Quit Chat Computer first."; exit 1; }
pgrep -f "cc-harness" >/dev/null && { echo "cc-harness is using the virtual Mac."; exit 1; }

cp "$ZIP" "$WORK/download.zip"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$WORK/download.zip"
ditto -x -k "$WORK/download.zip" "$WORK"
APP="$(find "$WORK" -maxdepth 1 -name "*.app" | head -1)"
say "app: $APP ($(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) build $(defaults read "$APP/Contents/Info.plist" CFBundleVersion))"
say "quarantine: $(xattr -p com.apple.quarantine "$APP" 2>/dev/null || echo none)"
spctl -a -vv -t exec "$APP" 2>&1 | tee -a "$LOG"
# With the quarantine flag, the first launch shows "downloaded from the Internet… Open?", which needs a click.
# Gatekeeper has accepted the app above; remove the flag so the rest runs unattended.
xattr -dr com.apple.quarantine "$APP"
say "Gatekeeper accepted the app; quarantine removed (a user would confirm Open once)"

restore() {
  say "restoring your data"
  pkill -TERM -f "$APP/Contents/MacOS/ChatComputer" 2>/dev/null || true
  for _ in $(seq 1 120); do pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null || break; sleep 1; done
  pkill -KILL -f "$APP/Contents/MacOS/ChatComputer" 2>/dev/null || true
  rm -rf "$NEW"
  [ -e "$BACKUP" ] && mv "$BACKUP" "$SUPPORT"
  defaults delete "$DOMAIN" 2>/dev/null || true
  [ -f "$WORK/defaults.plist" ] && defaults import "$DOMAIN" "$WORK/defaults.plist"
  say "restored"
}
defaults export "$DOMAIN" "$WORK/defaults.plist" 2>/dev/null || true
[ -e "$SUPPORT" ] && mv "$SUPPORT" "$BACKUP"
trap restore EXIT
trap 'exit 1' INT TERM
defaults delete "$DOMAIN" 2>/dev/null || true

shot() { python3 - "$WORK" "$1" <<'EOF' || true
import json, os, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20)
s.connect(os.path.expanduser("~/.chatcomputer/control.sock"))
s.sendall((json.dumps({"command": "dev_window_shot", "arguments": {"dir": sys.argv[1], "name": sys.argv[2]}, "client": "fresh"}) + "\n").encode())
print(s.recv(65536).decode().strip())
EOF
}
stage() { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['stage'])" "$NEW/ChatComputer.vm/spec.json" 2>/dev/null || echo none; }

STARTED=$(date +%s)
open --env CC_AUTO_ONBOARD=1 --env CC_DEV_WINDOW_SHOTS=1 --env CC_DEV_LOG="$WORK/onboarding.log" --env CC_GUEST_MACOS="${CC_GUEST_MACOS:-27}" \
  --env CC_RESTORE_IMAGE="${CC_RESTORE_IMAGE:-}" "$APP"
say "onboarding started"
LAST=none
while :; do
  NOW=$(stage)
  if [ "$NOW" != "$LAST" ]; then say "stage: $NOW (+$(( $(date +%s) - STARTED ))s)"; LAST=$NOW; fi
  [ "$NOW" = ready ] && break
  # Granting permissions operates the virtual Mac from the host, which needs the app in front (as when a user
  # clicks its window). Bring it forward, and keep a picture of each minute for diagnosis.
  if [ "$NOW" = provisioned ] || [ "$NOW" = agentInstalled ]; then
    TICK=$(( ${TICK:-0} + 1 ))
    if [ $(( TICK % 6 )) -eq 1 ]; then open "$APP"; shot "grant-$TICK"; fi
  fi
  if [ $(( $(date +%s) - STARTED )) -gt 5400 ]; then say "FAIL: onboarding did not finish in 90 minutes"; shot onboarding-timeout; exit 1; fi
  sleep 10
done
sleep 20
shot onboarding-done
say "onboarding finished in $(( $(date +%s) - STARTED ))s"

pkill -TERM -f "$APP/Contents/MacOS/ChatComputer"
for _ in $(seq 1 120); do pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null || break; sleep 1; done
cp "$BACKUP/credentials.json" "$NEW/credentials.json"
TASK_LOG="$WORK/task.log"
open --env CC_DEV_WINDOW_SHOTS=1 --env CC_DEV_MODEL="$MODEL" --env CC_DEV_LOG="$TASK_LOG" \
  --env CC_DEV_TASK="Use the Calculator app to compute 12 × 12 and tell me the result." "$APP"
say "task started with $MODEL"
T0=$(date +%s)
while :; do
  if grep -q "phase(ChatCore.TaskPhase.completed)" "$TASK_LOG" 2>/dev/null; then say "PASS: task completed in $(( $(date +%s) - T0 ))s"; break; fi
  if grep -qE "phase\(ChatCore.TaskPhase.(failed|cancelled)" "$TASK_LOG" 2>/dev/null; then say "FAIL: $(grep -E 'failed|cancelled' "$TASK_LOG" | tail -1)"; shot task-failed; exit 1; fi
  if [ $(( $(date +%s) - T0 )) -gt 900 ]; then say "FAIL: task did not finish in 15 minutes"; shot task-timeout; exit 1; fi
  sleep 5
done
grep -o "assistantNote([^)]*144[^)]*)" "$TASK_LOG" | tail -1 | tee -a "$LOG" || true
shot task-done
say "total $(( $(date +%s) - STARTED ))s"
