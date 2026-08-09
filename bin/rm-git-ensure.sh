#!/usr/bin/env bash
# rm-git-ensure.sh - Ensure a git project exists.
#
# Usage:
#   rm-git-ensure.sh <project-name> <git-url>      # Clone from URL into ./projects/<name>
#   rm-git-ensure.sh <project-name> <local-path>    # Reference an existing local path
#
# In the first form, if ./projects/<name> already exists and is a git repo,
# prints its path. If it doesn't exist, clones <git-url> into ./projects/<name>.
#
# In the second form, resolves <project-name> to ./projects/<name> and creates
# a symlink to <local-path> so the bare name can be used with rm-spawn.sh.
#
# Set RM_PROJECTS_OVERRIDE to change the projects directory.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/rm-lib.sh
. "$SCRIPT_DIR/rm-lib.sh"

usage() {
  echo "Usage: $0 <project-name> <git-url-or-local-path>"
  echo ""
  echo "Ensure a git project exists."
  echo "  <project-name>        Bare name (e.g. 'my-app') or path (with /)"
  echo "  <git-url-or-local-path>  Git URL to clone, or existing local path to reference"
}

NAME="${1:-}"
URL_OR_PATH="${2:-}"

[ -n "$NAME" ] || { usage >&2; exit 2; }
[ -n "$URL_OR_PATH" ] || { usage >&2; exit 2; }

# If the name is already a path (contains /), just verify it exists and is git
case "$NAME" in
  /*|*/*)
    RESOLVED=$(CDPATH='' cd -- "$NAME" 2>/dev/null && pwd -P 2>/dev/null || echo "$NAME")
    if [ -d "$RESOLVED/.git" ] || [ -f "$RESOLVED/.git" ]; then
      rm_log "using existing git project at $RESOLVED"
      printf '%s\n' "$RESOLVED"
      exit 0
    fi
    # Not a git repo — try to clone from URL_OR_PATH into this directory
    if [ -d "$RESOLVED" ]; then
      echo "error: $RESOLVED exists but is not a git repository" >&2
      exit 1
    fi
    rm_log "cloning $URL_OR_PATH into $RESOLVED..."
    mkdir -p "$(dirname "$RESOLVED")"
    git clone "$URL_OR_PATH" "$RESOLVED" 2>/dev/null || {
      rm_log_error "failed to clone $URL_OR_PATH"
      exit 1
    }
    printf '%s\n' "$RESOLVED"
    exit 0
    ;;
esac

# Bare name (no slash) — resolve under ./projects/
RESOLVED=$(rm_resolve_project_dir "$NAME")

if [ -d "$RESOLVED/.git" ] || [ -f "$RESOLVED/.git" ]; then
  rm_log "project already exists at $RESOLVED"
  printf '%s\n' "$RESOLVED"
  exit 0
fi

if [ -d "$RESOLVED" ]; then
  echo "error: $RESOLVED exists but is not a git repository" >&2
  exit 1
fi

# Check if the second argument is a local directory (existing path)
if [ -d "$URL_OR_PATH/.git" ] || [ -f "$URL_OR_PATH/.git" ]; then
  # Reference an existing local project by symlink
  local_path=$(CDPATH='' cd -- "$URL_OR_PATH" 2>/dev/null && pwd -P 2>/dev/null || echo "$URL_OR_PATH")
  rm_log "referencing existing local project at $local_path as '$NAME'..."
  mkdir -p "$(dirname "$RESOLVED")"
  ln -sfn "$local_path" "$RESOLVED" 2>/dev/null || {
    rm_log_error "failed to create symlink from $RESOLVED to $local_path"
    exit 1
  }
  printf '%s\n' "$local_path"
  exit 0
fi

# Clone from URL
rm_log "cloning $URL_OR_PATH into $RESOLVED..."
mkdir -p "$RM_PROJECTS"
git clone "$URL_OR_PATH" "$RESOLVED" 2>/dev/null || {
  rm_log_error "failed to clone $URL_OR_PATH"
  exit 1
}

printf '%s\n' "$RESOLVED"
