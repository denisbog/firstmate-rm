#!/usr/bin/env bash
# rm-merge.sh - Merge a task's branch into the default branch (local only).
#
# Usage:
#   rm-merge.sh <task-id> [project-dir]
#
# Merges the worktree branch (rm-task/<id>) into the main repo's default
# branch. The user must confirm via the main agent conversation before
# this is called — this script does not prompt.
#
# After merge, the worktree is destroyed (its branch is now part of main).
# The user still needs to push manually.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <task-id> [project-dir]"
}

TASK_ID="${1:-}"
[ -n "$TASK_ID" ] || { usage >&2; exit 2; }

# Verify the task is completed before merging
TASK_STATUS=$(rm_status_read "$TASK_ID" 2>/dev/null || echo "unknown")
if [ "$TASK_STATUS" != "completed" ]; then
  echo "error: task '$TASK_ID' has status '$TASK_STATUS', not 'completed'. Merge aborted." >&2
  exit 1
fi
rm_log "task '$TASK_ID' status is '$TASK_STATUS' — proceeding with merge"

# Determine the main repo path
GIT_ROOT=""
WORKTREE_BRANCH=""
WORKTREE_PATH=""

# Try reading from herdr meta first
GIT_ROOT=$(rm_read_herdr_meta_field "$TASK_ID" git_root 2>/dev/null || true)
WORKTREE_BRANCH=$(rm_read_herdr_meta_field "$TASK_ID" worktree 2>/dev/null \
  && git -C "$(rm_read_herdr_meta_field "$TASK_ID" worktree)" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
WORKTREE_PATH=$(rm_read_herdr_meta_field "$TASK_ID" worktree 2>/dev/null || true)

# If no git_root in meta, use project-dir arg
if [ -z "$GIT_ROOT" ] && [ $# -ge 2 ]; then
  GIT_ROOT=$(rm_git_root "${2}" 2>/dev/null || echo "${2}")
fi

# Derive branch from task id if not found
if [ -z "$WORKTREE_BRANCH" ]; then
  WORKTREE_BRANCH="rm-task/$TASK_ID"
fi

if [ -z "$GIT_ROOT" ] || [ ! -d "$GIT_ROOT/.git" ]; then
  echo "error: could not determine main repo path for task '$TASK_ID'" >&2
  exit 1
fi

rm_log "merging branch '$WORKTREE_BRANCH' into default branch in $GIT_ROOT..."

# Determine the default branch
DEFAULT_BRANCH=$(rm_default_branch "$GIT_ROOT" 2>/dev/null || echo "main")
rm_log "default branch: $DEFAULT_BRANCH"

# Ensure the task branch exists locally
if ! git -C "$GIT_ROOT" rev-parse --verify "$WORKTREE_BRANCH" 2>/dev/null >/dev/null; then
  echo "error: branch '$WORKTREE_BRANCH' not found in $GIT_ROOT" >&2
  exit 1
fi

# Switch to default branch and merge
rm_log "switching to '$DEFAULT_BRANCH'..."
git -C "$GIT_ROOT" checkout "$DEFAULT_BRANCH" 2>/dev/null || {
  echo "error: could not checkout '$DEFAULT_BRANCH'" >&2
  exit 1
}

# Pull latest if remote exists (user might have pushed since)
if git -C "$GIT_ROOT" remote get-url origin 2>/dev/null >/dev/null; then
  rm_log "pulling latest '$DEFAULT_BRANCH' from origin..."
  git -C "$GIT_ROOT" pull origin "$DEFAULT_BRANCH" 2>/dev/null || true
fi

# Perform the merge
rm_log "merging '$WORKTREE_BRANCH' into '$DEFAULT_BRANCH'..."
MERGE_OUTPUT=$(git -C "$GIT_ROOT" merge --no-ff -m "Merge task $TASK_ID: $WORKTREE_BRANCH" "$WORKTREE_BRANCH" 2>&1) || {
  echo "error: merge failed:" >&2
  echo "$MERGE_OUTPUT" >&2
  echo "" >&2
  echo "Resolve conflicts manually, then commit the merge." >&2
  echo "The worktree is still available at: $WORKTREE_PATH" >&2
  exit 1
}

printf '%s\n' "$MERGE_OUTPUT"

# Destroy the worktree now that its branch is merged
rm_log "merge successful — cleaning up worktree..."
"$SCRIPT_DIR/rm-herdr-workspace.sh" destroy "$TASK_ID" 2>/dev/null || true

rm_log "merge complete: '$WORKTREE_BRANCH' merged into '$DEFAULT_BRANCH'"
printf 'merged %s into %s\n' "$WORKTREE_BRANCH" "$DEFAULT_BRANCH"
