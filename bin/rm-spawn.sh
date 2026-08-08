#!/usr/bin/env bash
# rm-spawn.sh - Spawn a worker pi agent to perform a task in a herdr workspace.
#
# Usage:
#   rm-spawn.sh <task-id> <project-dir> [--model <name>] [--thinking <level>]
#
# This script:
#   1. Validates task-id and project directory
#   2. Ensures herdr session exists
#   3. Creates a herdr workspace/tab/pane for the task
#   4. Launches a pi agent in that pane with a task brief
#   5. Writes initial status to filesystem
#   6. Returns the target string

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <task-id> <project-dir> [--model <name>] [--thinking <level>]"
  echo ""
  echo "Spawn a worker pi agent for a task."
  echo ""
  echo "Arguments:"
  echo "  <task-id>       Short identifier for the task (alphanumeric, hyphens, underscores)"
  echo "  <project-dir>   Path to the git project directory"
  echo "  --model <name>  Pi model to use (optional)"
  echo "  --thinking <level>  Pi thinking level (low|medium|high|xhigh|max, optional)"
}

# Validate task id
validate_task_id() {
  local id=$1
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Generate a task brief from the task description + project context
generate_brief() {
  local task=$1 project=$2 task_desc="${3:-Implement the requested change.}"
  local brief_dir="$RM_DATA/$task"
  mkdir -p "$brief_dir"

  local project_name branch default_branch is_new
  project_name=$(basename "$(rm_git_root "$project" 2>/dev/null)" 2>/dev/null || echo "$project")
  branch=$(rm_current_branch "$project" 2>/dev/null || echo "unknown")
  default_branch=$(rm_default_branch "$project" 2>/dev/null || echo "main")

  # Detect if this is a brand-new project (no commits yet, or no remote)
  is_new=0
  if ! git -C "$project" rev-parse HEAD 2>/dev/null >/dev/null; then
    is_new=1  # no commits at all
  elif ! git -C "$project" remote get-url origin 2>/dev/null >/dev/null; then
    is_new=1  # no remote configured
  fi

  cat > "$brief_dir/brief.md" <<BRIEFEOF
# Task: $task

## Description
$task_desc

## Project
- Path: $(cd "$project" && pwd -P 2>/dev/null || echo "$project")
- Name: $project_name
- Current Branch: $branch
- Default Branch: $default_branch$([ "$is_new" -eq 1 ] && echo "
- Project Status: **New** (freshly created)")

## Instructions

You are a worker pi agent spawned by the main pi agent (firstmate-rm).

$([ "$is_new" -eq 1 ] && echo "This is a **new project** — no existing commits or remote." || echo "This is an **existing project**. The worktree is already on branch \`$branch\`.")

Your task:
1. Implement the changes described above.
2. Use the project's existing conventions and patterns.
3. Commit your changes to git.

When done:
1. Commit: \`git add -A && git commit -m "..."\`
2. Call the extension tools below to report completion.

## Status Communication

Use the extension tools (registered automatically) to report status:

| Tool | When to use |
|------|-------------|
| \`rm_report_status working "..."\` | Progress update |
| \`rm_report_status blocked "..."\` | Need user input (call \`rm_write_blocking_question\` first) |
| \`rm_report_status completed "..."\` | Finished (call \`rm_write_done_report\` and \`rm_write_last_message\` first) |
| \`rm_report_status failed "..."\` | Cannot complete |

Your status files are written to \`$RM_STATUS_DIR/\` and the main
agent picks them up automatically. You do not need to run shell scripts
for status reporting — use the tools above.
BRIEFEOF

  printf '%s\n' "$brief_dir/brief.md"
}

# Main
MODEL=""
THINKING=""
POSITIONAL=()
WANT_VALUE=""

for a in "$@"; do
  if [ -n "$WANT_VALUE" ]; then
    case "$WANT_VALUE" in
      model) MODEL=$a ;;
      thinking) THINKING=$a ;;
    esac
    WANT_VALUE=""
    continue
  fi
  case "$a" in
    --model) WANT_VALUE=model ;;
    --thinking) WANT_VALUE=thinking ;;
    --model=*) MODEL=${a#--model=} ;;
    --thinking=*) THINKING=${a#--thinking=} ;;
    --help|-h) usage; exit 0 ;;
    *) POSITIONAL+=("$a") ;;
  esac
done

[ "${#POSITIONAL[@]}" -ge 2 ] || { usage >&2; exit 2; }

TASK_ID=${POSITIONAL[0]}
PROJECT_DIR=${POSITIONAL[1]}
TASK_DESC="${POSITIONAL[2]:-Implement the requested change.}"

validate_task_id "$TASK_ID" || { echo "error: invalid task id '$TASK_ID'" >&2; exit 2; }

# Resolve project directory: bare names (no slash) land in ./projects/
PROJECT_DIR=$(rm_resolve_project_dir "$PROJECT_DIR")
[ -d "$PROJECT_DIR" ] || { echo "error: project directory '$PROJECT_DIR' does not exist" >&2; exit 2; }

# Ensure git project
rm_git_root "$PROJECT_DIR" >/dev/null 2>&1 || {
  echo "error: '$PROJECT_DIR' is not inside a git repository" >&2
  exit 2
}

# Check if task already exists
existing_status=$(rm_status_read "$TASK_ID" 2>/dev/null || true)
if [ "$existing_status" != "unknown" ] && [ -n "$existing_status" ]; then
  echo "error: task '$TASK_ID' already exists with status '$existing_status'" >&2
  exit 1
fi

# Ensure main identity
MAIN_ID=$(rm_ensure_identity)

# Create herdr workspace (creates an isolated git worktree with its own branch)
TARGET=$("$SCRIPT_DIR/rm-herdr-workspace.sh" create "$TASK_ID" "$PROJECT_DIR") || {
  rm_log_error "failed to create herdr workspace"
  exit 1
}

# Get pane id for the target
PANE_ID=$("$SCRIPT_DIR/rm-herdr-workspace.sh" get-pane "$TASK_ID") || {
  rm_log_error "failed to get pane id"
  exit 1
}

# Read the worktree path from meta — this is the isolated project dir for the worker
WORKER_PROJECT_DIR=$(rm_read_herdr_meta_field "$TASK_ID" worktree 2>/dev/null || echo "$PROJECT_DIR")
rm_log "worker project dir: $WORKER_PROJECT_DIR"

# Generate task brief using the worktree path (which is always the worker's checkout)
BRIEF_FILE=$(generate_brief "$TASK_ID" "$WORKER_PROJECT_DIR" "$TASK_DESC")
rm_log "brief written to $BRIEF_FILE"

# Write initial status
rm_status_write "$TASK_ID" "spawned" "Worker agent launched"
rm_write_last_message "$TASK_ID" "Task '$TASK_ID' started. Working directory: $WORKER_PROJECT_DIR"

# Build pi launch command — session-id is the task id so main pi can resume it
PI_EXT_ARG="--extension $RM_HOME/lib/rm-worker-ext.ts"
PI_MODEL_ARG=""
PI_THINKING_ARG=""
PI_SESSION_ID="rm-$TASK_ID"
[ -n "$MODEL" ] && PI_MODEL_ARG="--model $MODEL"
[ -n "$THINKING" ] && PI_THINKING_ARG="--thinking $THINKING"

# Write the launch script to the shared state directory
LAUNCH_SCRIPT="$RM_STATE/$TASK_ID.launch.sh"
cat > "$LAUNCH_SCRIPT" << LAUNCHSCRIPT
#!/usr/bin/env bash
# Launch script for worker pi agent - generated by rm-spawn.sh
set -eu

RM_HOME='$RM_HOME'
RM_ROOT_OVERRIDE='$RM_ROOT'
RM_STATE_OVERRIDE='$RM_STATE'
RM_DATA_OVERRIDE='$RM_DATA'
RM_TASK_ID='$TASK_ID'
RM_PARENT_IDENTITY='$MAIN_ID'
BRIEF_FILE='$BRIEF_FILE'
PI_EXT='$RM_HOME/lib/rm-worker-ext.ts'
PROJECT_DIR='$(cd "$WORKER_PROJECT_DIR" && pwd -P)'
MODEL_FLAG='$PI_MODEL_ARG'
THINKING_FLAG='$PI_THINKING_ARG'
PI_SESSION_ID='$PI_SESSION_ID'

# Source the rm-lib
. "\$RM_HOME/bin/rm-lib.sh"

# Notify parent that we're starting
rm_status_write "\$RM_TASK_ID" "working" "Worker pi agent started"

# Read the brief
BRIEF=\$(cat "\$BRIEF_FILE")

# Launch pi with the extension — known session-id lets main pi resume
# shellcheck disable=SC2086
cd "\$PROJECT_DIR" && \
  RM_HOME="\$RM_HOME" \
  RM_ROOT_OVERRIDE="\$RM_ROOT_OVERRIDE" \
  RM_STATE_OVERRIDE="\$RM_STATE_OVERRIDE" \
  RM_DATA_OVERRIDE="\$RM_DATA_OVERRIDE" \
  RM_TASK_ID="\$RM_TASK_ID" \
  RM_PARENT_IDENTITY="\$RM_PARENT_IDENTITY" \
  RM_WORKER_MODE="1" \
  PI_SESSION_ID="\$PI_SESSION_ID" \
  pi \$MODEL_FLAG \$THINKING_FLAG \
    --session-id "\$PI_SESSION_ID" \
    -e "\$PI_EXT" "\$BRIEF"
LAUNCHSCRIPT
chmod +x "$LAUNCH_SCRIPT"
rm_log "launch script written to $LAUNCH_SCRIPT"

# Launch pi in the herdr pane via pane run (single command, no timing hacks)
LAUNCH_CMD="bash '$LAUNCH_SCRIPT'"
rm_log "executing launch command in pane $PANE_ID..."

if ! rm_herdr_cli pane run "$PANE_ID" "$LAUNCH_CMD" 2>/dev/null; then
  rm_log_error "failed to execute launch command in pane"
  exit 1
fi

# Write final status
rm_status_write "$TASK_ID" "working" "Worker deployed"
rm_log "worker for task '$TASK_ID' launched in pane $PANE_ID"
printf 'spawned %s target=%s pane=%s\n' "$TASK_ID" "$TARGET" "$PANE_ID"
