#!/usr/bin/env bash
# rm-peek.sh - Read the last message/output from a worker's pane.
#
# Usage:
#   rm-peek.sh <task-id> [lines]
#
# Captures the last N lines of output from the worker's herdr pane.
# Default lines is 40.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

TASK_ID="${1:-}"
[ -n "$TASK_ID" ] || { echo "usage: $0 <task-id> [lines]" >&2; exit 2; }
LINES="${2:-40}"

# Get the pane id
PANE_ID=$("$SCRIPT_DIR/rm-herdr-workspace.sh" get-pane "$TASK_ID" 2>/dev/null) || {
  rm_log_error "no herdr workspace for task '$TASK_ID'"
  exit 1
}
SESSION=$(rm_read_herdr_meta_field "$TASK_ID" session 2>/dev/null) || SESSION=$(rm_herdr_session)

# Capture the last N lines from the pane
rm_herdr_cli pane capture --pane "$PANE_ID" --lines "$LINES" 2>/dev/null || {
  rm_log_error "failed to capture pane output for task '$TASK_ID'"
  exit 1
}
