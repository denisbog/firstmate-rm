# firstmate-rm (Remote Manager)

Spawn and monitor worker pi agents that implement changes in git projects, each in their own herdr workspace, creating merge requests and reporting status via filesystem files.

## Requirements

- **pi** — The pi coding agent CLI (`npm install -g @earendil-works/pi-coding-agent`)
- **herdr** — Terminal multiplexer (https://herdr.dev)
- **gh** — GitHub CLI (`gh auth login`)

## Quick Start

```bash
# Navigate to the project directory
cd /path/to/your-project

# Run the main pi agent with the watch extension
pi -e /path/to/firstmate-rm/.pi/extensions/rm-watch.ts

# Inside pi, spawn a worker:
# Use the rm_spawn_worker tool with:
#   taskId: "fix-auth-bug"
#   projectDir: "/path/to/your-project"
#   description: "Fix the authentication bug in login.ts"
```

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
         │  spawns / monitors                     │  creates PR
         ▼                                        ▼
   User interaction                        GitHub PR
```

## Files

| Path | Purpose |
|------|---------|
| `AGENTS.md` | Agent instructions for main pi |
| `bin/rm-lib.sh` | Shared library (status files, identity, helpers) |
| `bin/rm-spawn.sh` | Spawn a worker pi agent in a herdr workspace |
| `bin/rm-herdr-workspace.sh` | Create/manage herdr workspaces |
| `bin/rm-status.sh` | Read/write status files |
| `bin/rm-send.sh` | Send input to a worker pane |
| `bin/rm-peek.sh` | Read output from a worker pane |
| `bin/rm-pr.sh` | Create and check PRs |
| `bin/rm-cleanup.sh` | Clean up after PR merge |
| `.pi/extensions/rm-watch.ts` | Main agent extension (status watcher) |
| `.pi/extensions/rm-worker-ext.ts` | Worker agent extension (status reporting) |

## Workflow

1. **Spawn**: User asks for a change → main agent spawns a worker with `rm_spawn_worker`
2. **Implement**: Worker pi agent works in a herdr workspace, reports status
3. **Block**: If worker needs input → reports `blocked` → main agent presents question to user → relays answer
4. **Complete**: Worker finishes → creates PR → reports `completed` with summary
5. **Review** (optional): User can spawn a reviewer to comment on the PR
6. **Merge**: User merges the PR → main agent verifies and cleans up
