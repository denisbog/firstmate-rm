#!/usr/bin/env bash
# rm-lib.sh - shared library for firstmate-rm (remote-manager).
#
# Sourced by every rm-*.sh script. Provides:
#   - Status file management (read/write/append)
#   - Identity token generation for main/spawned agents
#   - Logging helpers
#   - Path resolution

RM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RM_ROOT="${RM_ROOT_OVERRIDE:-$(cd "$RM_SCRIPT_DIR/.." && pwd)}"
RM_HOME="${RM_HOME:-${RM_ROOT_OVERRIDE:-$RM_ROOT}}"
RM_STATE="${RM_STATE_OVERRIDE:-$RM_HOME/state}"
RM_DATA="${RM_DATA_OVERRIDE:-$RM_HOME/data}"
RM_PROJECTS="${RM_PROJECTS_OVERRIDE:-$RM_HOME/projects}"

# Identity: each home gets a machine-local id so spawned agents can identify
# their parent. Written once; live for the life of the home.
RM_IDENTITY_FILE="$RM_STATE/.rm-identity"

# Status directories
RM_STATUS_DIR="$RM_STATE/workers"

# Status file paths
rm_task_status_file() {  # <task-id>
  printf '%s/%s.status' "$RM_STATUS_DIR" "$1"
}

rm_task_lock_file() {  # <task-id>
  printf '%s/%s.lock' "$RM_STATUS_DIR" "$1"
}

rm_task_lastmsg_file() {  # <task-id>
  printf '%s/%s.lastmsg' "$RM_STATUS_DIR" "$1"
}

rm_task_blocking_question_file() {  # <task-id>
  printf '%s/%s.blocking-question' "$RM_STATUS_DIR" "$1"
}

rm_task_blocking_answer_file() {  # <task-id>
  printf '%s/%s.blocking-answer' "$RM_STATUS_DIR" "$1"
}

rm_task_done_report_file() {  # <task-id>
  printf '%s/%s.done-report' "$RM_STATUS_DIR" "$1"
}

# --- Identity ---

rm_ensure_identity() {
  mkdir -p "$RM_STATE" "$RM_STATUS_DIR"
  if [ ! -f "$RM_IDENTITY_FILE" ]; then
    local id
    id=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null \
      | base64 \
      | tr '+/' '-_' \
      | tr -d '=\r\n') || id="rm-$$-$(date +%s)"
    printf '%s\n' "$id" > "$RM_IDENTITY_FILE"
  fi
  head -1 "$RM_IDENTITY_FILE"
}

rm_main_identity() {
  rm_ensure_identity
}

rm_worker_identity() {  # <task-id>
  local task_id=$1
  printf 'worker-%s' "$task_id"
}

# --- Status file reading/writing ---

# rm_status_write <task-id> <status> [message...]
# Atomically writes the status (overwrites).
rm_status_write() {
  local task=$1 status=$2
  shift 2
  local file
  file=$(rm_task_status_file "$task")
  mkdir -p "$(dirname "$file")"
  local tmp
  tmp=$(mktemp "$file.XXXXXX") || return 1
  printf 'status=%s\n' "$status" > "$tmp"
  if [ $# -gt 0 ]; then
    printf 'message=%s\n' "$*" >> "$tmp"
  fi
  printf 'ts=%s\n' "$(date +%s)" >> "$tmp"
  printf 'worker_id=%s\n' "$(rm_worker_identity "$task")" >> "$tmp"
  mv -f "$tmp" "$file"
  if [ $# -gt 0 ]; then
    rm_log "status: $task -> $status ($*)"
  else
    rm_log "status: $task -> $status"
  fi
}

# rm_status_append <task-id> <key>=<value>...
# Appends to the status file (for logs/events).
rm_status_append() {
  local task=$1
  shift
  local file
  file=$(rm_task_status_file "$task")
  mkdir -p "$(dirname "$file")"
  {
    printf 'ts=%s\n' "$(date +%s)"
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } >> "$file"
}

# rm_status_read <task-id> -> reads the status
rm_status_read() {
  local task=$1 file
  file=$(rm_task_status_file "$task")
  if [ ! -f "$file" ]; then
    printf 'unknown'
    return 1
  fi
  grep '^status=' "$file" 2>/dev/null | head -1 | cut -d= -f2- || printf 'unknown'
}

# rm_status_field <task-id> <field>
rm_status_field() {
  local task=$1 field=$2 file
  file=$(rm_task_status_file "$task")
  [ -f "$file" ] || return 1
  grep "^${field}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-
}

# --- Last message ---

rm_write_last_message() {  # <task-id> <text>
  local task=$1 text=$2 file
  file=$(rm_task_lastmsg_file "$task")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$text" > "$file"
}

rm_read_last_message() {  # <task-id>
  local task=$1 file
  file=$(rm_task_lastmsg_file "$task")
  [ -f "$file" ] && cat "$file" || printf '(no message)'
}

# --- Blocking question/answer ---

rm_write_blocking_question() {  # <task-id> <question-text>
  local task=$1 question=$2 file
  file=$(rm_task_blocking_question_file "$task")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$question" > "$file"
}

rm_read_blocking_question() {  # <task-id>
  local task=$1 file
  file=$(rm_task_blocking_question_file "$task")
  [ -f "$file" ] && cat "$file" || printf '(no question)'
}

rm_write_blocking_answer() {  # <task-id> <answer-text>
  local task=$1 answer=$2 file
  file=$(rm_task_blocking_answer_file "$task")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$answer" > "$file"
  # Signal that answer is ready by writing status
  rm_status_append "$task" "event=answer_provided"
}

rm_read_blocking_answer() {  # <task-id>
  local task=$1 file
  file=$(rm_task_blocking_answer_file "$task")
  [ -f "$file" ] && cat "$file" || return 1
}

rm_clear_blocking() {
  local task=$1
  rm -f "$(rm_task_blocking_question_file "$task")" "$(rm_task_blocking_answer_file "$task")"
}

# --- Done report ---

rm_write_done_report() {  # <task-id> <report-text>
  local task=$1 report=$2 file
  file=$(rm_task_done_report_file "$task")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$report" > "$file"
}

rm_read_done_report() {  # <task-id>
  local task=$1 file
  file=$(rm_task_done_report_file "$task")
  [ -f "$file" ] && cat "$file" || printf '(no report)'
}

# --- PR info ---

# --- Cleanup ---

rm_cleanup_task() {  # <task-id>
  local task=$1
  rm -f "$(rm_task_status_file "$task")"
  rm -f "$(rm_task_lastmsg_file "$task")"
  rm -f "$(rm_task_blocking_question_file "$task")"
  rm -f "$(rm_task_blocking_answer_file "$task")"
  rm -f "$(rm_task_done_report_file "$task")"
  rm -f "$(rm_task_lock_file "$task")"
  rm -f "$RM_STATUS_DIR/$task.session"
  rm -rf "$RM_DATA/$task"
  rm_log "cleanup: removed all state for task $task"
}

# --- All known tasks ---

rm_list_tasks() {
  local status_dir=$RM_STATUS_DIR
  [ -d "$status_dir" ] || return 0
  for f in "$status_dir"/*.status; do
    [ -f "$f" ] || continue
    basename "$f" .status
  done
}

rm_tasks_by_status() {  # <status>
  local want=$1 task actual
  rm_list_tasks | while IFS= read -r task; do
    actual=$(rm_status_read "$task" 2>/dev/null || true)
    [ "$actual" = "$want" ] && printf '%s\n' "$task"
  done
}

# --- Lock ---

rm_lock_acquire() {  # <task-id> -> fd
  local task=$1 file lock_fd
  file=$(rm_task_lock_file "$task")
  mkdir -p "$(dirname "$file")"
  exec {lock_fd}>"$file" || return 1
  if ! flock -n "$lock_fd"; then
    exec {lock_fd}>&-
    return 1
  fi
  printf '%s' "$lock_fd"
}

rm_lock_release() {  # <fd>
  local fd=$1
  exec {fd}>&-
}

rm_wait_lock() {  # <task-id>
  local task=$1 file lock_fd
  file=$(rm_task_lock_file "$task")
  mkdir -p "$(dirname "$file")"
  exec {lock_fd}>"$file" || return 1
  flock "$lock_fd"
  printf '%s' "$lock_fd"
}

# --- Logging ---

rm_log() {
  printf '[rm] %s\n' "$*" >&2
}

rm_log_info() {
  printf '[rm] INFO: %s\n' "$*"
}

rm_log_error() {
  printf '[rm] ERROR: %s\n' "$*" >&2
}

# --- Herdr helpers ---

rm_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

rm_herdr_cli() {
  local session
  session=$(rm_herdr_session)
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

rm_herdr_workspace_label() {  # <task-id>
  printf 'rm-%s' "$1"
}

rm_herdr_tab_label() {  # <task-id>
  printf 'fm-%s' "$1"
}

# Herdr workspace metadata directory (shared across all scripts)
RM_HERDR_META_DIR="$RM_STATE/herdr"

# Write herdr task meta for later cleanup
rm_write_herdr_meta() {  # <task-id> <session> <workspace> <tab> <pane> <worktree>
  local task=$1 session=$2 workspace=$3 tab=$4 pane=$5 worktree=$6
  mkdir -p "$RM_HERDR_META_DIR"
  {
    printf 'task_id=%s\n' "$task"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'worktree=%s\n' "$worktree"
    printf 'ts=%s\n' "$(date +%s)"
  } > "$RM_HERDR_META_DIR/$task.meta"
}

rm_read_herdr_meta_field() {  # <task-id> <field>
  local task=$1 field=$2 meta
  meta="$RM_HERDR_META_DIR/$task.meta"
  [ -f "$meta" ] || return 1
  grep "^${field}=" "$meta" | head -1 | cut -d= -f2-
}

# --- Project directory resolution ---

# rm_resolve_project_dir <name-or-path>
# When the argument is an absolute path or a path with a slash, use it as-is.
# When it is a bare name (no slash), treat it as a project name under ./projects/.
# Creates the projects directory if needed.
rm_resolve_project_dir() {
  local input=$1 resolved
  case "$input" in
    /*|*/*)
      resolved=$(CDPATH='' cd -- "$input" 2>/dev/null && pwd -P 2>/dev/null || echo "$input")
      ;;
    *)
      mkdir -p "$RM_PROJECTS"
      resolved="$RM_PROJECTS/$input"
      ;;
  esac
  printf '%s\n' "$resolved"
}

# rm_git_ensure <project-name-or-path> [git-url]
# Ensure a git repo exists at the resolved path.
# If it doesn't exist and git-url is provided, clone it.
rm_git_ensure() {
  local input=$1 git_url=${2:-} dir
  dir=$(rm_resolve_project_dir "$input")
  if [ -d "$dir/.git" ]; then
    rm_log "using existing project at $dir"
    printf '%s\n' "$dir"
    return 0
  fi
  if [ -d "$dir" ]; then
    rm_log_error "$dir exists but is not a git repository"
    return 1
  fi
  if [ -n "$git_url" ]; then
    rm_log "cloning $git_url into $dir..."
    mkdir -p "$RM_PROJECTS"
    git clone "$git_url" "$dir" 2>/dev/null || {
      rm_log_error "failed to clone $git_url"
      return 1
    }
    printf '%s\n' "$dir"
    return 0
  fi
  rm_log_error "$dir does not exist and no git-url provided"
  return 1
}

# --- git project detection ---

rm_git_root() {  # <dir>
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

rm_current_branch() {  # <dir>
  local dir=$1 branch
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  # HEAD means no commits yet — fall back to 'main'
  if [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
    printf 'main'
  else
    printf '%s' "$branch"
  fi
}

rm_default_branch() {  # <dir>
  local dir=$1 branch
  branch=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^refs/remotes/origin/||')
  if [ -n "$branch" ]; then
    printf '%s' "$branch"
    return 0
  fi
  # No remote configured — default to main (don't use current branch;
  # with worktrees the current branch is rm-task/<id>)
  printf 'main'
}

# --- git project detection (continued) ---
