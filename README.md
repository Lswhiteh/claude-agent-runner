# claude-agent-runner

Autonomous Claude Code agent orchestrator. Polls Linear for labeled issues, spawns isolated Claude instances in git worktrees, runs CI gates, and opens GitHub PRs — fully hands-off.

## Features

- **Linear-driven**: Label an issue → agent picks it up, implements, opens a PR
- **Isolated worktrees**: Each agent works in its own git worktree (outside the repo to avoid bundler conflicts)
- **Docker DB isolation**: Per-agent Postgres containers with random ephemeral ports
- **CI gate**: Deterministic checks (typecheck, test, build) with auto-fix retries
- **Feedback resume**: Re-label an issue to resume with PR review feedback
- **Auto-review**: Spawns a read-only Claude to review PRs with structured feedback
- **Auto-fix loop**: Iterates review → fix → CI → push until approved (configurable max)
- **Pipeline**: Parse a requirements markdown into Linear issues with dependency chains
- **Dependency sequencing**: Only pick up issues whose blockers are completed
- **Guardrails**: Hook blocks destructive commands (rm -rf, force-push, DROP TABLE) in agent mode
- **Multi-workspace**: Support multiple Linear workspaces and teams
- **Slack notifications**: Optional webhook notifications at key lifecycle points

## Quick Start

```bash
git clone https://github.com/Lswhiteh/claude-agent-runner.git
cd claude-agent-runner
./setup.sh
```

Then:
1. Edit `~/.config/claude-agents/secrets.env` with your API keys
2. Edit `~/.config/claude-agents/config.json` with your repos
3. Label a Linear issue with "Agent" and run `claude-agent-runner`

## Usage

```bash
# Poll all workspaces (default)
claude-agent-runner

# Poll with auto-review of created PRs
claude-agent-runner --auto-review

# Poll with auto-review + auto-fix loop
claude-agent-runner --auto-fix

# Only pick up issues with completed blockers
claude-agent-runner --sequenced

# Parse requirements into Linear issues
claude-agent-runner --pipeline requirements.md --workspace myapp --team Engineering
claude-agent-runner --pipeline requirements.md --dry-run

# Standalone PR review
claude-agent-runner --review-pr 42 --repo /path/to/repo

# Clean up merged worktrees
claude-agent-runner --cleanup

# Show active agents and pending issues
claude-agent-runner --status
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

## Requirements

- `jq`, `git`, `gh` (GitHub CLI), `curl`
- `claude` (Claude Code CLI)
- `docker` (only if using `local_db`)
- `pnpm` (only for Node.js projects)

## License

MIT
