# firstmate-rm (Remote Manager)

Spawn and monitor worker pi agents that implement changes in git projects, each in their own herdr workspace, creating merge requests and reporting status via filesystem files.

## Requirements

- **pi** — The pi coding agent CLI (`npm install -g @earendil-works/pi-coding-agent`)
- **herdr** — Terminal multiplexer (https://herdr.dev)

## Quick Start

```bash
# Run the main pi agent with the watch extension
pi -e /path/to/firstmate-rm/.pi/extensions/rm-watch.ts

# Inside pi, spawn a worker referencing a local project by absolute path:
#   bash bin/rm-spawn.sh add-logging /home/user/my-project "Add structured logging"
```

## Two ways to reference a project

| Mode | Syntax | Example | Description |
|------|--------|---------|-------------|
| **Managed** (projects dir) | Bare name (no slash) | `my-app` | Resolves to `./projects/<name>`. Clone or init there first. |
| **Local file path** | Absolute or relative path (with slash) | `/home/user/code/my-app` or `../other-project` | Used as-is. The project must already exist at that path. |

## How It Works

```
┌─────────────────┐     status files      ┌──────────────────┐
│  Main Pi Agent  │◄───────watch─────────►│  Worker Pi Agent │
│  (with rm-watch │     state/workers/    │  (with rm-worker │
│   extension)    │       *.status        │   extension)     │
│                 │       *.lastmsg       │                  │
│                 │       *.blocking-*    │  herdr workspace │
│                 │       *.done-report   │  rm-<task-id>    │
└────────┬────────┘                       └──────────────────┘
         │                                        │
         │  spawns / monitors                     │  commits changes
         ▼                                        ▼
   User interaction                        Task branch
```

## Files

| Path | Purpose |
|------|---------|
| `AGENTS.md` | Agent instructions for main pi |
| `bin/rm-lib.sh` | Shared library (status files, identity, helpers, path resolution) |
| `bin/rm-spawn.sh` | Spawn a worker pi agent in a herdr workspace |
| `bin/rm-herdr-workspace.sh` | Create/manage herdr workspaces and git worktrees |
| `bin/rm-status.sh` | Read/write status files |
| `bin/rm-send.sh` | Send input to a worker pane |
| `bin/rm-peek.sh` | Read output from a worker pane |
| `bin/rm-pr.sh` | Show branch info for completed tasks |
| `bin/rm-git-ensure.sh` | Ensure a git project exists (clone or reference local path) |
| `bin/rm-cleanup.sh` | Clean up workspace after task completion |
| `.pi/extensions/rm-watch.ts` | Main agent extension (status watcher) |
| `lib/rm-worker-ext.ts` | Worker agent extension (status reporting, loaded explicitly) |

## Local file path usage

If you have a project already on disk (e.g. `/home/user/repos/my-app`), just pass that path directly:

```bash
# Spawn a worker on a local project
bash bin/rm-spawn.sh fix-login /home/user/repos/my-app "Fix login redirect bug"

# Or use a relative path
bash bin/rm-spawn.sh add-api ../../adjacent-project "Add REST API endpoints"
```

The system creates an isolated git worktree in a herdr workspace — the original project is untouched.

## Managed projects usage

For repos you want to store centrally under firstmate-rm:

```bash
# Clone a repo into ./projects/
bash bin/rm-git-ensure.sh my-app https://github.com/user/my-app.git

# Or reference an existing local path (creates a symlink reference)
bash bin/rm-git-ensure.sh my-app /home/user/existing/my-app

# Then spawn using the bare name:
bash bin/rm-spawn.sh fix-login my-app "Fix login redirect bug"
```

## Workflow

1. **Spawn**: User asks for a change → main agent spawns a worker with `bash bin/rm-spawn.sh`
2. **Implement**: Worker pi agent works in a herdr workspace, reports status
3. **Block**: If worker needs input → reports `blocked` → main agent presents question to user → relays answer
4. **Complete**: Worker finishes → commits changes to the task branch → reports `completed` with summary
5. **Push/Merge**: User inspects the worktree, pushes the branch, and merges manually (standard git)
6. **Cleanup**: Main agent destroys the herdr workspace, removes status files, and prunes the worktree
