#!/bin/sh
# Source this file, then run_checked LOG PATTERN COMMAND [ARG...]. Filtering must
# never replace the command's exit status. Keep the complete log for diagnosis.
onboarding_failed() {
  grep -Eq 'onboarding: .* failed:|permission: setup-failed|permission: setup-cancelled' "$1" 2>/dev/null
}

run_checked() {
  check_log=$1
  check_pattern=$2
  shift 2
  mkdir -p "$(dirname "$check_log")"
  if "$@" >"$check_log" 2>&1; then
    grep -E "$check_pattern" "$check_log" || true
  else
    check_status=$?
    cat "$check_log" >&2
    echo "FAIL: command exited $check_status (full log: $check_log)" >&2
    return "$check_status"
  fi
}
