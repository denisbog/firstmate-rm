#!/usr/bin/env bash
# rm-pr.sh - Show branch info for a completed task (git-only, no gh).
#
# Usage:
#   rm-pr.sh status <task-id> [project-dir]
#   rm-pr.sh diff <task-id> [project-dir]
#   rm-pr.sh branch <task-id> [project-dir]
#
# Since pushes and PRs are done manually by the user, this script just
# provides information about the task's worktree and branch so the user
# knows what to push.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <command> <task-id> [project-dir]"
  echo ""
  echo "Commands:"
  echo "  status <task-id>   Show branch, worktree path, and commit summary"
  echo "  diff <task-id>     Show the diff for the task branch"
  echo "  branch <task-id>   Print the branch name (for manual push)"
}

get_worktree_path() {
  local task=$1
  rm_read_herdr_meta_field "$task" worktree 2>/dev/null || true
}

case "${1:-help}" in
  status)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    TASK=$2
    WORKTREE=$(get_worktree_path "$TASK")
    if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE/.git" ] && [ ! -f "$WORKTREE/.git" ]; then
      # Not a worktree meta — maybe project-dir was given
      WORKTREE="${3:-}"
    fi
    if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
      echo "error: could not find worktree for task '$TASK'" >&2
      exit 1
    fi

    BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    COMMIT=$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || echo "none")
    SUMMARY=$(git -C "$WORKTREE" log --oneline -1 2>/dev/null || echo "(no commits)")
    REMOTE=$(git -C "$WORKTREE" remote get-url origin 2>/dev/null || echo "(no remote configured)")

    echo "Task:    $TASK"
    echo "Branch:  $BRANCH"
    echo "Commit:  $COMMIT"
    echo "Summary: $SUMMARY"
    echo "Worktree: $WORKTREE"
    echo "Remote:  $REMOTE"
    echo ""
    echo "To push: git push origin $BRANCH"
    ;;

  diff)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    TASK=$2
    WORKTREE=$(get_worktree_path "$TASK")
    if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
      WORKTREE="${3:-}"
    fi
    if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
      echo "error: could not find worktree for task '$TASK'" >&2
      exit 1
    fi

    BASE=$(rm_default_branch "$WORKTREE" 2>/dev/null || echo "main")
    exec git -C "$WORKTREE" diff "$BASE"..HEAD
    ;;

  branch)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    TASK=$2
    WORKTREE=$(get_worktree_path "$TASK")
    if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
      WORKTREE="${3:-}"
    fi
    if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
      echo "error: could not find worktree for task '$TASK'" >&2
      exit 1
    fi
    git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
    ;;

  help|--help|-h)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
