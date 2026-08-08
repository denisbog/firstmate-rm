#!/usr/bin/env bash
# rm-git-ensure.sh - Ensure a git project exists under ./projects/.
#
# Usage:
#   rm-git-ensure.sh <project-name> <git-url>
#
# If ./projects/<name> already exists and is a git repo, prints its path.
# If it doesn't exist, clones <git-url> into ./projects/<name>.
# Fails if the directory exists but is not a git repo.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <project-name> <git-url>"
  echo ""
  echo "Ensure a git project exists under ./projects/."
  echo "  <project-name>  Bare name (e.g. 'my-app') resolves to ./projects/my-app"
  echo "  <git-url>       Git URL to clone if the project doesn't exist yet"
}

NAME="${1:-}"
GIT_URL="${2:-}"

[ -n "$NAME" ] || { usage >&2; exit 2; }
[ -n "$GIT_URL" ] || { usage >&2; exit 2; }

# Resolve to a path under projects/
RESOLVED=$(rm_resolve_project_dir "$NAME")

if [ -d "$RESOLVED/.git" ]; then
  rm_log "project already exists at $RESOLVED"
  printf '%s\n' "$RESOLVED"
  exit 0
fi

if [ -d "$RESOLVED" ]; then
  echo "error: $RESOLVED exists but is not a git repository" >&2
  exit 1
fi

rm_log "cloning $GIT_URL into $RESOLVED..."
mkdir -p "$RM_PROJECTS"
git clone "$GIT_URL" "$RESOLVED" 2>/dev/null || {
  rm_log_error "failed to clone $GIT_URL"
  exit 1
}

printf '%s\n' "$RESOLVED"
