#!/bin/sh
# Fresh-install test (STATUS.md 1.0, item 4): installs a release zip as a new user would, on this Mac.
#
#   scripts/fresh-install.sh build/release/ChatComputer.zip [deepseek:openAI:deepseek-flash]
#   CC_GUEST_MACOS=26 scripts/fresh-install.sh …   installs macOS 26 instead of 27
#   CC_RESTORE_IMAGE=path.ipsw scripts/fresh-install.sh …   installs from a local restore image (no download)
#   CC_DATA_DIR=/absolute/new/test-folder scripts/fresh-install.sh …
#     keeps the test VM there and leaves your data folder and preferences alone
#
# 1. Copies the zip with a quarantine flag (as a browser download has), unzips it and checks Gatekeeper.
# 2. Moves your Chat Computer data folder (~/.chatcomputer, or the one chosen in setup) and preferences aside.
# 3. Launches with CC_AUTO_ONBOARD=1: downloads macOS (~26 GB), installs it, creates the account, installs the agent,
#    grants its permissions and saves the starting point. Times each step from the VM's spec.json.
# 4. Relaunches with your stored API key and a model, and runs one task end to end.
# 5. Stops the app, then restores your data/preferences, or retains an isolated test folder.
# Output: a log in /tmp/chatcomputer-fresh-install-<time>/ with screenshots of the window on failure.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/check-output.sh"
ZIP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
MODEL="${2:-deepseek:openAI:deepseek-flash}"
DOMAIN=app.chatcomputer.ChatComputer
ISOLATED=0
if [ -n "${CC_DATA_DIR:-}" ]; then
  ISOLATED=1
  NEW=$(python3 -c 'from pathlib import Path; import sys
p = Path(sys.argv[1]).expanduser()
if p.exists() or p.is_symlink():
    sys.exit("The isolated test folder must not exist: " + str(p))
print(p.resolve())' "$CC_DATA_DIR")
  [ ! -e "$NEW" ] && [ ! -L "$NEW" ] || { echo "The isolated test folder must not exist: $NEW"; exit 1; }
else
  NEW="$HOME/.chatcomputer"
fi
# Your data folder, put back at the end; the new install uses the default folder.
SUPPORT="$(defaults read "$DOMAIN" DataDirectory 2>/dev/null || echo "$HOME/.chatcomputer")"
BACKUP="$SUPPORT.fresh-install-backup"
WORK="/tmp/chatcomputer-fresh-install-$(date +%Y%m%d-%H%M%S)"
LOG="$WORK/log.txt"
mkdir -p "$WORK"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

if [ "$ISOLATED" -eq 0 ]; then
  [ -e "$BACKUP" ] && { echo "A backup from an earlier run is still at $BACKUP. Put it back first."; exit 1; }
  [ "$SUPPORT" != "$NEW" ] && [ -e "$NEW" ] && { echo "$NEW exists but isn't your data folder ($SUPPORT). Move it first."; exit 1; }
fi
pgrep -f "ChatComputer.app/Contents/MacOS/ChatComputer" >/dev/null && { echo "Quit Chat Computer first."; exit 1; }
pgrep -f "cc-harness" >/dev/null && { echo "cc-harness is using the virtual Mac."; exit 1; }

cp "$ZIP" "$WORK/download.zip"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$WORK/download.zip"
ditto -x -k "$WORK/download.zip" "$WORK"
APP="$(find "$WORK" -maxdepth 1 -name "*.app" | head -1)"
say "app: $APP ($(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) build $(defaults read "$APP/Contents/Info.plist" CFBundleVersion))"
say "quarantine: $(xattr -p com.apple.quarantine "$APP" 2>/dev/null || echo none)"
run_checked "$WORK/gatekeeper.log" '.' spctl -a -vv -t exec "$APP"
cat "$WORK/gatekeeper.log" >>"$LOG"
# With the quarantine flag, the first launch shows "downloaded from the Internet… Open?", which needs a click.
# Gatekeeper has accepted the app above; remove the flag so the rest runs unattended.
xattr -dr com.apple.quarantine "$APP"
say "Gatekeeper accepted the app; quarantine removed (a user would confirm Open once)"

restore() {
  say "stopping the test app"
  pkill -TERM -f "$APP/Contents/MacOS/ChatComputer" 2>/dev/null || true
  for _ in $(seq 1 120); do pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null || break; sleep 1; done
  if pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null; then
    say "FAIL: app did not stop after SIGTERM; leaving data and backup in place for recovery"
    return 1
  fi
  if [ "$ISOLATED" -eq 1 ]; then
    say "test data retained at $NEW; your data and preferences were not moved"
  else
    rm -rf "$NEW"
    [ -e "$BACKUP" ] && mv "$BACKUP" "$SUPPORT"
    defaults delete "$DOMAIN" 2>/dev/null || true
    [ -f "$WORK/defaults.plist" ] && defaults import "$DOMAIN" "$WORK/defaults.plist"
    say "restored"
  fi
}
if [ "$ISOLATED" -eq 0 ]; then
  defaults export "$DOMAIN" "$WORK/defaults.plist" 2>/dev/null || true
  [ -e "$SUPPORT" ] && mv "$SUPPORT" "$BACKUP"
fi
trap 'install_result=$?; restore || install_result=1; exit "$install_result"' EXIT
trap 'exit 1' INT TERM
if [ "$ISOLATED" -eq 0 ]; then defaults delete "$DOMAIN" 2>/dev/null || true; fi

shot() { python3 - "$WORK" "$1" "$NEW" <<'EOF' || true
import json, os, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20)
s.connect(os.path.join(sys.argv[3], "control.sock"))
s.sendall((json.dumps({"command": "dev_window_shot", "arguments": {"dir": sys.argv[1], "name": sys.argv[2]}, "client": "fresh"}) + "\n").encode())
print(s.recv(65536).decode().strip())
EOF
}
stage() { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['stage'])" "$NEW/ChatComputer.vm/spec.json" 2>/dev/null || echo none; }

STARTED=$(date +%s)
open --env CC_DATA_DIR="$NEW" --env CC_AUTO_ONBOARD=1 --env CC_DEV_WINDOW_SHOTS=1 --env CC_DEV_LOG="$WORK/onboarding.log" --env CC_GUEST_MACOS="${CC_GUEST_MACOS:-27}" \
  --env CC_RESTORE_IMAGE="${CC_RESTORE_IMAGE:-}" "$APP"
say "onboarding started"
LAST=none
while :; do
  NOW=$(stage)
  if [ "$NOW" != "$LAST" ]; then say "stage: $NOW (+$(( $(date +%s) - STARTED ))s)"; LAST=$NOW; fi
  [ "$NOW" = ready ] && break
  if onboarding_failed "$WORK/onboarding.log"; then
    say "FAIL: onboarding stopped; see onboarding.log"
    shot onboarding-failed
    exit 1
  fi
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
pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null && { say "FAIL: app did not quit before the first model task"; exit 1; }
CREDENTIALS="$BACKUP/credentials.json"
if [ "$ISOLATED" -eq 1 ]; then CREDENTIALS="$SUPPORT/credentials.json"; fi
if [ ! -f "$CREDENTIALS" ]; then
  say "SKIPPED: real model task requires credentials.json; install alone is not a passed end-to-end test"
  exit 77
fi
cp "$CREDENTIALS" "$NEW/credentials.json"
TASK_LOG="$WORK/task.log"
DOC_NAME="fresh-install-$(date +%s).txt"
DOC_TEXT="Chat Computer fresh install check"
open --env CC_DATA_DIR="$NEW" --env CC_DEV_WINDOW_SHOTS=1 --env CC_DEV_MODEL="$MODEL" --env CC_DEV_LOG="$TASK_LOG" \
  --env CC_DEV_TASK="In TextEdit, create a plain-text document containing exactly: $DOC_TEXT. Save it as $DOC_NAME in the outbox." "$APP"
say "task started with $MODEL"
T0=$(date +%s)
while :; do
  if grep -q "phase(ChatCore.TaskPhase.completed)" "$TASK_LOG" 2>/dev/null; then say "PASS: task completed in $(( $(date +%s) - T0 ))s"; break; fi
  if grep -qE "phase\(ChatCore.TaskPhase.(failed|cancelled)" "$TASK_LOG" 2>/dev/null; then say "FAIL: $(grep -E 'failed|cancelled' "$TASK_LOG" | tail -1)"; shot task-failed; exit 1; fi
  if [ $(( $(date +%s) - T0 )) -gt 900 ]; then say "FAIL: task did not finish in 15 minutes"; shot task-timeout; exit 1; fi
  sleep 5
done
python3 "$ROOT/scripts/check-first-file.py" "$NEW/ChatComputer.vm/Shared/outbox" "$DOC_NAME" "$DOC_TEXT"
shot task-done

# A second task after a real quit/relaunch must produce a new file; an old output
# cannot make a failed resume look successful.
pkill -TERM -f "$APP/Contents/MacOS/ChatComputer"
for _ in $(seq 1 120); do pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null || break; sleep 1; done
pgrep -f "$APP/Contents/MacOS/ChatComputer" >/dev/null && { say "FAIL: app did not quit before the restart check"; exit 1; }
REOPEN_LOG="$WORK/reopen.log"
REOPEN_NAME="reopen-$DOC_NAME"
open --env CC_DATA_DIR="$NEW" --env CC_DEV_WINDOW_SHOTS=1 --env CC_DEV_MODEL="$MODEL" --env CC_DEV_LOG="$REOPEN_LOG" \
  --env CC_DEV_TASK="In TextEdit, create a new plain-text document containing exactly: $DOC_TEXT. Save it as $REOPEN_NAME in the outbox." "$APP"
T0=$(date +%s)
while :; do
  if grep -q "phase(ChatCore.TaskPhase.completed)" "$REOPEN_LOG" 2>/dev/null; then break; fi
  if grep -qE 'phase\(ChatCore.TaskPhase.(failed|cancelled)' "$REOPEN_LOG" 2>/dev/null; then say "FAIL: task failed after reopening"; exit 1; fi
  if [ $(( $(date +%s) - T0 )) -gt 900 ]; then say "FAIL: reopened task timed out"; exit 1; fi
  sleep 5
done
python3 "$ROOT/scripts/check-first-file.py" "$NEW/ChatComputer.vm/Shared/outbox" "$REOPEN_NAME" "$DOC_TEXT"
say "PASS: fresh file content checked before and after reopening"
say "total $(( $(date +%s) - STARTED ))s"
