#!/usr/bin/env bash
# rm-send.sh - Send a message/input to a worker's herdr pane.
#
# Usage:
#   rm-send.sh <task-id> <text...>
#   rm-send.sh <task-id> --key <key-name>
#
# Sends text (followed by Enter) or special keys to the worker's pane.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <task-id> <text...>"
  echo "       $0 <task-id> --key <key-name>"
  echo ""
  echo "Keys: Enter, Escape, C-c"
}

TASK_ID="${1:-}"
[ -n "$TASK_ID" ] || { usage >&2; exit 2; }
shift

# Get the pane id
PANE_ID=$("$SCRIPT_DIR/rm-herdr-workspace.sh" get-pane "$TASK_ID" 2>/dev/null) || {
  rm_log_error "no herdr workspace for task '$TASK_ID'"
  exit 1
}
SESSION=$(rm_read_herdr_meta_field "$TASK_ID" session 2>/dev/null) || SESSION=$(rm_herdr_session)

if [ "${1:-}" = "--key" ]; then
  [ $# -ge 2 ] || { usage >&2; exit 2; }
  KEY=$2
  case "$KEY" in
    Enter)     echo "sending Enter to $TASK_ID..." >&2; rm_herdr_cli pane send-key --pane "$PANE_ID" --key Enter >/dev/null 2>&1 ;;
    Escape)    echo "sending Escape to $TASK_ID..." >&2; rm_herdr_cli pane send-key --pane "$PANE_ID" --key Escape >/dev/null 2>&1 ;;
    C-c|CtrlC) echo "sending Ctrl-C to $TASK_ID..." >&2; rm_herdr_cli pane send-key --pane "$PANE_ID" --key CtrlC >/dev/null 2>&1 ;;
    *) echo "error: unknown key '$KEY' (supported: Enter, Escape, C-c)" >&2; exit 2 ;;
  esac
else
  TEXT="$*"
  echo "sending text to $TASK_ID..." >&2
  # Send the text line by line
  printf '%s\n' "$TEXT" | while IFS= read -r line; do
    rm_herdr_cli pane send-text --pane "$PANE_ID" "$line" >/dev/null 2>&1 || true
    sleep 0.1
  done
  # Send Enter to submit
  sleep 0.3
  rm_herdr_cli pane send-key --pane "$PANE_ID" --key Enter >/dev/null 2>&1 || true
fi
