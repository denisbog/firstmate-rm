#!/usr/bin/env bash
# rm-status.sh - Read/write status files for worker agents.
#
# Usage:
#   rm-status.sh write <task-id> <status> [message...]
#   rm-status.sh read <task-id>
#   rm-status.sh field <task-id> <field>
#   rm-status.sh write-lastmsg <task-id> <text>
#   rm-status.sh read-lastmsg <task-id>
#   rm-status.sh write-blocking-question <task-id> <text>
#   rm-status.sh read-blocking-question <task-id>
#   rm-status.sh write-blocking-answer <task-id> <text>
#   rm-status.sh read-blocking-answer <task-id>
#   rm-status.sh clear-blocking <task-id>
#   rm-status.sh write-done-report <task-id> <text>
#   rm-status.sh read-done-report <task-id>
#   rm-status.sh write-pr-info <task-id> <url> [description...]
#   rm-status.sh read-pr-url <task-id>
#   rm-status.sh list [<status>]
#   rm-status.sh wait-for <task-id> <status> [timeout-seconds]
#   rm-status.sh cleanup <task-id>

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <command> [args...]"
  echo ""
  echo "Commands:"
  echo "  write <task-id> <status> [message...]   Write status (overwrites)"
  echo "  read <task-id>                           Read current status"
  echo "  field <task-id> <field>                  Read a specific field from status"
  echo "  write-lastmsg <task-id> <text>           Write last message"
  echo "  read-lastmsg <task-id>                   Read last message"
  echo "  write-blocking-question <task-id> <text> Write blocking question"
  echo "  read-blocking-question <task-id>         Read blocking question"
  echo "  write-blocking-answer <task-id> <text>   Write blocking answer"
  echo "  read-blocking-answer <task-id>           Read blocking answer"
  echo "  clear-blocking <task-id>                 Clear blocking state"
  echo "  write-done-report <task-id> <text>       Write done report"
  echo "  read-done-report <task-id>               Read done report"
  echo "  write-pr-info <task-id> <url> [desc]     Write PR info"
  echo "  read-pr-url <task-id>                    Read PR URL"
  echo "  list [<status>]                          List tasks (optionally filtered by status)"
  echo "  cleanup <task-id>                        Remove all state for a task"
}

case "${1:-help}" in
  write)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    shift 1
    rm_status_write "$@"
    ;;
  read)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_status_read "$2"
    ;;
  field)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    rm_status_field "$2" "$3" || exit 1
    ;;
  write-lastmsg)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    shift 1
    rm_write_last_message "$@"
    ;;
  read-lastmsg)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_read_last_message "$2"
    ;;
  write-blocking-question)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    shift 1
    rm_write_blocking_question "$@"
    ;;
  read-blocking-question)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_read_blocking_question "$2"
    ;;
  write-blocking-answer)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    shift 1
    rm_write_blocking_answer "$@"
    ;;
  read-blocking-answer)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_read_blocking_answer "$2" || exit 1
    ;;
  clear-blocking)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_clear_blocking "$2"
    ;;
  write-done-report)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    shift 1
    rm_write_done_report "$@"
    ;;
  read-done-report)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_read_done_report "$2"
    ;;
  write-pr-info)
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    rm_write_pr_info "$2" "$3" "${4:-}"
    ;;
  read-pr-url)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_read_pr_url "$2" || exit 1
    ;;
  list)
    if [ $# -ge 2 ]; then
      rm_tasks_by_status "$2"
    else
      rm_list_tasks
    fi
    ;;
  # wait-for is intentionally absent. Use the extension's async polling
  # (rm-watch.ts) instead of blocking the agent. The extension registers a
  # watch via the status poll loop and notifies you when the target status
  # is reached — non-blocking.
  cleanup)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    rm_cleanup_task "$2"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
