#!/usr/bin/env bash
# rm-cleanup.sh - Clean up workspace and status after a task is done.
#
# Usage:
#   rm-cleanup.sh <task-id> [project-dir]
#
# Does:
#   1. Destroys the herdr workspace (removes git worktree)
#   2. Removes all status files and launch script
#   3. Cleans up stale worktree references
#
# The user is responsible for pushing and merging manually.
# This just removes the local workspace artifacts.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <task-id> [project-dir]"
  echo ""
  echo "Clean up a task's herdr workspace, status files, and local branch."
}

TASK_ID="${1:-}"
[ -n "$TASK_ID" ] || { usage >&2; exit 2; }
shift

PROJECT_DIR="${1:-}"

rm_log "cleaning up task '$TASK_ID'..."

# 1. Destroy herdr workspace (removes git worktree + closes workspace)
rm_log "destroying herdr workspace..."
"$SCRIPT_DIR/rm-herdr-workspace.sh" destroy "$TASK_ID" 2>/dev/null || {
  rm_log "warning: could not destroy herdr workspace (may have been already cleaned up)"
}

# 2. Remove status files
rm_log "removing status files..."
rm_cleanup_task "$TASK_ID"

# 3. Remove launch script
LAUNCH_SCRIPT="$RM_STATE/$TASK_ID.launch.sh"
rm -f "$LAUNCH_SCRIPT"
rm_log "removed launch script"

# 4. Prune stale git worktree references from the main repo (safety net)
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.git" ]; then
  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
fi

rm_log "cleanup complete for task '$TASK_ID'"

# Hint for the user
if [ -n "$PROJECT_DIR" ]; then
  rm_log "the local branch may still exist in $PROJECT_DIR if you need to push it later"
fi
