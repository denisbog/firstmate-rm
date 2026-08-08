#!/usr/bin/env bash
# rm-herdr-workspace.sh - Create/manage herdr worktree-backed workspaces for task agents.
#
# Usage:
#   rm-herdr-workspace.sh create <task-id> <project-dir>   # Create git worktree + herdr workspace
#   rm-herdr-workspace.sh destroy <task-id>                 # Remove worktree and close workspace
#   rm-herdr-workspace.sh get-pane <task-id>                # Print the pane id
#   rm-herdr-workspace.sh target <task-id>                  # Print the backend target string
#   rm-herdr-workspace.sh list-tasks                        # List all rm-* workspaces
#   rm-herdr-workspace.sh ensure-session                    # Ensure a herdr session exists

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

# Ensure a herdr session exists; start one if needed
ensure_session() {
  local session
  session=$(rm_herdr_session)
  if ! rm_herdr_cli session list --json 2>/dev/null \
    | jq -e --arg s "$session" '.sessions[]? | select(.name == $s and .running == true)' >/dev/null 2>&1; then
    rm_log "starting herdr session '$session'..."
    rm_herdr_cli session start 2>/dev/null || {
      rm_log_error "failed to start herdr session '$session'"
      return 1
    }
    rm_log "herdr session '$session' started"
  fi
}

# Create a herdr workspace for a task, backed by an isolated git worktree.
# Falls back to a manual workspace/tab/pane for repos with no commits.
create_workspace() {
  local task=$1 project=$2
  local session workspace_label default_branch worktree_branch

  ensure_session || return 1

  session=$(rm_herdr_session)
  workspace_label=$(rm_herdr_workspace_label "$task")
  worktree_branch="rm-task/$task"

  rm_log "creating herdr worktree for task '$task' in project '$project'..."

  default_branch=$(rm_default_branch "$project" 2>/dev/null || echo "main")

  # Check if the repo has at least one commit (required for git worktree)
  local has_commits=0
  if git -C "$project" rev-parse HEAD 2>/dev/null >/dev/null; then
    has_commits=1
  fi

  if [ "$has_commits" -eq 1 ]; then
    # Use herdr worktree create for full isolation
    local create_out
    create_out=$(rm_herdr_cli worktree create \
      --cwd "$project" \
      --branch "$worktree_branch" \
      --base "$default_branch" \
      --label "$workspace_label" \
      --json 2>&1) || {
      rm_log_error "herdr worktree create failed: $create_out"
      return 1
    }

    local workspace_id tab_id pane_id worktree_path
    workspace_id=$(printf '%s' "$create_out" | jq -er '.result.workspace.workspace_id // empty' 2>/dev/null) || {
      rm_log_error "could not parse workspace_id"
      return 1
    }
    tab_id=$(printf '%s' "$create_out" | jq -er '.result.tab.tab_id // empty' 2>/dev/null) || {
      rm_log_error "could not parse tab_id"
      return 1
    }
    pane_id=$(printf '%s' "$create_out" | jq -er '.result.root_pane.pane_id // empty' 2>/dev/null) || {
      rm_log_error "could not parse pane_id"
      return 1
    }
    worktree_path=$(printf '%s' "$create_out" | jq -er '.result.worktree.path // empty' 2>/dev/null) || {
      rm_log_error "could not parse worktree path"
      return 1
    }

    rm_log "worktree created: workspace=$workspace_id pane=$pane_id path=$worktree_path"

    # Write meta — worktree_path becomes the worker's isolated project dir
    rm_write_herdr_meta "$task" "$session" "$workspace_id" "$tab_id" "$pane_id" "$worktree_path"
    printf 'git_root=%s\n' "$(cd "$project" && pwd -P)" >> "$RM_HERDR_META_DIR/$task.meta"

    local target_str="$session:$pane_id"
    printf '%s\n' "$target_str"
    rm_log "target: $target_str"
    return 0
  else
    # Fallback for empty repos: manual workspace/tab/pane (no git worktree possible)
    rm_log "repo has no commits yet; using manual workspace (no git worktree)"

    local tab_label workspace_id tab_id pane_id target_str
    tab_label=$(rm_herdr_tab_label "$task")

    local create_out
    create_out=$(rm_herdr_cli workspace create --label "$workspace_label" 2>&1) || {
      rm_log "workspace may already exist; attempting reuse..."
    }

    local list_out
    list_out=$(rm_herdr_cli workspace list 2>/dev/null) || {
      rm_log_error "could not list workspaces"
      return 1
    }

    workspace_id=$(printf '%s' "$list_out" | jq -er --arg label "$workspace_label" '
      [.result.workspaces[]? | select(.label == $label)] | first | .workspace_id // empty
    ' 2>/dev/null) || {
      rm_log_error "could not find or create workspace '$workspace_label'"
      return 1
    }

    local tab_out
    tab_out=$(rm_herdr_cli tab create --workspace "$workspace_id" --label "$tab_label" 2>/dev/null) || {
      rm_log_error "could not create tab '$tab_label'"
      return 1
    }
    tab_id=$(printf '%s' "$tab_out" | jq -er '.result.tab.tab_id // empty' 2>/dev/null) || {
      rm_log_error "could not get tab id"
      return 1
    }
    pane_id=$(printf '%s' "$tab_out" | jq -er '.result.root_pane.pane_id // empty' 2>/dev/null) || {
      rm_log_error "could not find pane"
      return 1
    }

    rm_herdr_cli tab focus "$tab_id" >/dev/null 2>&1 || true

    # Write meta with original project path (shared checkout for empty repos)
    rm_write_herdr_meta "$task" "$session" "$workspace_id" "$tab_id" "$pane_id" "$project"
    printf 'git_root=%s\n' "$(cd "$project" && pwd -P)" >> "$RM_HERDR_META_DIR/$task.meta"

    target_str="$session:$pane_id"
    printf '%s\n' "$target_str"
    rm_log "target: $target_str (shared checkout)"
    return 0
  fi
}

# Destroy a task's herdr workspace (worktree or manual).
destroy_workspace() {
  local task=$1 workspace_id session git_root

  workspace_id=$(rm_read_herdr_meta_field "$task" workspace_id) || true
  session=$(rm_read_herdr_meta_field "$task" session) || session=$(rm_herdr_session)
  git_root=$(rm_read_herdr_meta_field "$task" git_root 2>/dev/null || true)

  if [ -n "$workspace_id" ]; then
    rm_log "removing herdr worktree via workspace $workspace_id..."
    if ! rm_herdr_cli worktree remove --workspace "$workspace_id" 2>/dev/null; then
      rm_log "retrying with --force..."
      rm_herdr_cli worktree remove --workspace "$workspace_id" --force 2>/dev/null || {
        rm_log "falling back to manual workspace close..."
        rm_herdr_cli workspace close "$workspace_id" 2>/dev/null || true
      }
    fi
  else
    # No workspace_id in meta — try to find by label and remove as worktree
    local workspace_label
    workspace_label=$(rm_herdr_workspace_label "$task")
    local list_out
    list_out=$(rm_herdr_cli workspace list 2>/dev/null || true)
    workspace_id=$(printf '%s' "$list_out" | jq -er --arg label "$workspace_label" '
      [.result.workspaces[]? | select(.label == $label)] | first | .workspace_id // empty
    ' 2>/dev/null || true)
    if [ -n "$workspace_id" ]; then
      rm_herdr_cli worktree remove --workspace "$workspace_id" --force 2>/dev/null || true
    fi
  fi

  # Prune stale git worktree references (safety net)
  if [ -n "$git_root" ] && [ -d "$git_root/.git" ]; then
    git -C "$git_root" worktree prune 2>/dev/null || true
  fi

  # Remove meta file
  rm -f "$RM_HERDR_META_DIR/$task.meta"
  rm_log "workspace cleanup complete for task '$task'"
}

# Get pane id for a task
get_pane() {
  local task=$1 pane_id
  pane_id=$(rm_read_herdr_meta_field "$task" pane_id) || {
    rm_log_error "no pane metadata for task '$task'"
    return 1
  }
  printf '%s\n' "$pane_id"
}

# Get target string (session:pane_id)
get_target() {
  local task=$1 pane_id session
  pane_id=$(rm_read_herdr_meta_field "$task" pane_id) || {
    rm_log_error "no pane metadata for task '$task'"
    return 1
  }
  session=$(rm_read_herdr_meta_field "$task" session) || session=$(rm_herdr_session)
  printf '%s:%s\n' "$session" "$pane_id"
}

# List all rm-* workspaces in herdr
list_tasks() {
  rm_herdr_cli workspace list 2>/dev/null | jq -r '
    .result.workspaces[]? | select(.label // "" | startswith("rm-")) | .label
  ' 2>/dev/null | sed 's/^rm-//'
}

# Main dispatch
case "${1:-help}" in
  create)
    [ $# -ge 3 ] || { echo "usage: $0 create <task-id> <project-dir>" >&2; exit 2; }
    create_workspace "$2" "$3"
    ;;
  destroy)
    [ $# -ge 2 ] || { echo "usage: $0 destroy <task-id>" >&2; exit 2; }
    destroy_workspace "$2"
    ;;
  get-pane)
    [ $# -ge 2 ] || { echo "usage: $0 get-pane <task-id>" >&2; exit 2; }
    get_pane "$2"
    ;;
  target)
    [ $# -ge 2 ] || { echo "usage: $0 target <task-id>" >&2; exit 2; }
    get_target "$2"
    ;;
  list-tasks)
    list_tasks
    ;;
  ensure-session)
    ensure_session
    ;;
  *)
    echo "Usage: $0 <command> [args...]"
    echo "Commands:"
    echo "  create <task-id> <project-dir>   Create git worktree + herdr workspace"
    echo "  destroy <task-id>                 Remove worktree and close workspace"
    echo "  get-pane <task-id>                Print the pane id"
    echo "  target <task-id>                  Print the backend target string"
    echo "  list-tasks                        List all rm-* workspaces"
    echo "  ensure-session                    Ensure a herdr session exists"
    exit 2
    ;;
esac
