# car (Claude Agent Runner)

Autonomous Claude Code agent orchestrator. Polls Linear for labeled issues, spawns isolated Claude instances in git worktrees, runs CI gates, and opens GitHub PRs — fully hands-off.

## Features

- **Linear-driven**: Label an issue → agent picks it up, implements, opens a PR
- **Isolated worktrees**: Each agent works in its own git worktree (outside the repo to avoid bundler conflicts)
- **Docker DB isolation**: Per-agent Postgres containers with random ephemeral ports
- **CI gate**: Deterministic checks (typecheck, test, build) with auto-fix retries
- **Feedback resume**: Re-label an issue to resume with PR review feedback
- **Auto-review**: Spawns a read-only Claude to review PRs with structured feedback
- **Auto-fix loop**: Iterates review → fix → CI → push until approved (configurable max)
- **Orchestration**: Multi-agent decomposition — add the "Orchestrate" label to break a ticket into scoped subtasks with a supervisor
- **Scoped workers**: File-scope enforcement via hook — workers can only write to their assigned files
- **Pipeline**: Parse a requirements markdown into Linear issues with dependency chains
- **Spec generation**: Turn a free-form idea into structured requirements with `--spec`
- **Dependency sequencing**: Only pick up issues whose blockers are completed
- **Guardrails**: Hooks block destructive commands and enforce file scope in agent mode
- **Multi-workspace**: Support multiple Linear workspaces and teams
- **Slack notifications**: Optional webhook notifications at key lifecycle points
- **Event tracing**: JSONL traces per issue with CLI viewer and browser timeline

## Quick Start

```bash
git clone https://github.com/Lswhiteh/claude-agent-runner.git
cd claude-agent-runner
./setup.sh
```

Then:
1. Edit `~/.config/claude-agents/secrets.env` with your API keys
2. Edit `~/.config/claude-agents/config.json` with your repos
3. Label a Linear issue with "Agent" and run `car`

## Usage

```bash
# Poll all workspaces (default)
car

# Poll with auto-review of created PRs
car --auto-review

# Poll with auto-review + auto-fix loop
car --auto-fix

# Only pick up issues with completed blockers
car --sequenced

# Parse requirements into Linear issues
car --pipeline requirements.md --workspace myapp --team Engineering
car --pipeline requirements.md --dry-run

# Generate spec from an idea, optionally create Linear issues
car --spec idea.md
car --spec idea.md --interactive
car --spec idea.md --create

# Standalone PR review
car --review-pr 42 --repo /path/to/repo

# Clean up merged worktrees
car --cleanup

# Show active agents and pending issues
car --status

# Query event traces
agent-trace list                    # List all traces
agent-trace show ENG-123            # Pretty-print a trace
agent-trace tail ENG-123            # Live-tail events
agent-trace view                    # Open browser timeline viewer
```

## Configuration

`~/.config/claude-agents/config.json`:

```json
{
  "label": "Agent",
  "max_parallel": 3,
  "max_turns": 15,
  "max_ci_retries": 3,
  "max_review_fix_iterations": 3,
  "ci_gate_path": "",
  "orchestrator": {
    "enabled": false,
    "label": "Orchestrate",
    "max_subtasks": 8,
    "max_orchestrator_turns": 50,
    "poll_interval_seconds": 30,
    "max_validation_retries": 2
  },
  "workspaces": {
    "myapp": {
      "api_key_env": "LINEAR_API_KEY_MYAPP",
      "slack_webhook_env": "SLACK_WEBHOOK_MYAPP",
      "teams": {
        "Engineering": {
          "repo": "/path/to/repo",
          "local_db": "postgres"
        }
      }
    }
  }
}
```

### Config Fields

| Field | Default | Description |
|-------|---------|-------------|
| `label` | `"Agent"` | Linear label that triggers agent pickup |
| `max_parallel` | `3` | Max concurrent agents per repo |
| `max_turns` | `15` | Max Claude turns per agent session |
| `max_ci_retries` | `3` | CI gate retry attempts with auto-fix |
| `max_review_fix_iterations` | `3` | Auto-fix loop iterations |
| `ci_gate_path` | `""` | Explicit path to ci-gate (auto-detected if empty) |

### Orchestrator Fields

| Field | Default | Description |
|-------|---------|-------------|
| `orchestrator.enabled` | `false` | Enable multi-agent orchestration |
| `orchestrator.label` | `"Orchestrate"` | Linear label that triggers orchestration |
| `orchestrator.max_subtasks` | `8` | Max subtasks per decomposition |
| `orchestrator.max_orchestrator_turns` | `50` | Claude turns for decomposition |
| `orchestrator.poll_interval_seconds` | `30` | Supervisor polling interval |
| `orchestrator.max_validation_retries` | `2` | Retries for failed subtask validation |

### Team Fields

| Field | Values | Description |
|-------|--------|-------------|
| `repo` | path | Absolute path to the git repo |
| `local_db` | `"postgres"`, `"supabase"`, omit | Docker DB type per agent |

### API Key Resolution

1. Config `api_key_env` → named env var
2. `LINEAR_API_KEY_<WORKSPACE>` (auto-derived, uppercased)
3. `LINEAR_API_KEY` (global fallback)

### Slack Webhook Resolution

1. Config `slack_webhook_env` → named env var
2. `SLACK_WEBHOOK_<WORKSPACE>` (auto-derived)
3. No fallback — silent if not configured

## How It Works

```
1. Label a Linear issue with "Agent"
2. Runner polls Linear, finds the issue
3. Creates isolated worktree + optional Docker DB
4. Spawns Claude with full issue context
5. Claude implements, writes tests, makes atomic commits
6. Runner runs CI gate (typecheck, test, build)
7. If CI fails: spawns Claude to fix, retries up to N times
8. Pushes branch, creates GitHub PR
9. Optional: auto-review → auto-fix loop
10. Posts implementation report to Linear
```

### Orchestrated Multi-Agent

For complex, multi-concern features:

```
1. Add "Agent" + "Orchestrate" labels to a Linear issue
2. Runner spawns an orchestrator Claude to decompose the issue
3. Orchestrator explores codebase, creates scoped subtask JSON files
4. Runner creates Linear sub-issues with file scope metadata
5. Sub-issues get "Agent" label → picked up as scoped workers
6. Workers implement within their file scope (enforced by scope-guard hook)
7. Orchestrator polls for completion, handles scope overflow
8. After all subtasks done: integration CI → combined PR
```

If the orchestrator decides the issue doesn't need decomposition (single-concern), it falls back to the standard single-agent flow automatically.

### Spec Generation

Turn ideas into actionable Linear issues:

```bash
# Generate structured requirements from a free-form idea
car --spec idea.md

# Interactive mode — Claude asks clarifying questions
car --spec idea.md --interactive

# Generate and create Linear issues in one step
car --spec idea.md --create
```

### Feedback Resume

When a reviewer leaves feedback on the PR or Linear ticket:
1. Re-add the "Agent" label to the issue
2. Runner detects existing worktree + PR
3. Gathers feedback from GitHub (PR comments, reviews, inline comments) and Linear
4. Spawns Claude with full feedback context
5. Claude makes new commits (no amend/force-push)
6. Runner pushes to existing PR

### Blocking

If the agent can't proceed:
1. Agent writes questions to `.claude/agent-blocked/<ID>.md`
2. Runner posts questions to Linear
3. Developer replies on Linear
4. Re-add "Agent" label → agent resumes with answers

### Event Tracing

Every issue run emits structured JSONL events (~30 event types across 7 categories) to `~/.config/claude-agents/traces/`.

```bash
# CLI tool
agent-trace list                    # List all traces
agent-trace show ENG-123            # Pretty-print events for an issue
agent-trace tail ENG-123            # Live-tail (like tail -f)
agent-trace view                    # Open browser timeline viewer
agent-trace view ENG-123            # Open viewer filtered to one trace
```

The timeline viewer is a single-file HTML app (no build step) with color-coded events, filter chips, search, auto-refresh, and swimlane view for orchestrated issues.

### Status

```bash
car --status
```

Shows all configured workspaces/teams, active agents with PIDs and issue IDs, and pending issue counts per team.

## Documentation

- [Walkthrough](docs/walkthrough.md) — linear narrative of the full system
- [Slide deck](docs/walkthrough-slides.html) — 20-slide HTML presentation (open in browser)

## Requirements

- `jq`, `git`, `gh` (GitHub CLI), `curl`
- `claude` (Claude Code CLI)
- `docker` (only if using `local_db`)
- `pnpm` (only for Node.js projects)

## License

MIT
