# claude-agent-runner

Autonomous Claude agent orchestrator that polls Linear for labeled issues, spawns isolated Claude instances in git worktrees, runs CI, and opens GitHub PRs.

## Project Structure

```
bin/
  claude-agent-runner       Main orchestrator script
  ci-gate                   Deterministic CI checks before push

hooks/
  block-destructive.sh      PreToolUse guardrail (blocks rm -rf, force-push, etc. in agent mode)

skills/                     Claude Code skills for agent use
  agent-report/             Implementation summary generation
  backend/                  Backend implementation guidance
  blocked/                  Blocked-question filing
  ci-fix/                   CI failure resolution
  data-flow/                Data flow analysis
  debug/                    Debugging guidance
  frontend/                 Frontend implementation guidance
  implement/                Feature implementation workflow
  review-pr/                PR review guidance
  simplify/                 Code simplification

config/
  config.example.json       Config template with all fields documented

setup.sh                    One-command install: symlinks, hooks, skills, config
```

## Key Architecture

### Agent Runner (~1200 lines bash)
- **Polling**: Fetches Linear issues labeled with configurable label (default: "Agent")
- **Worktrees**: Creates isolated worktrees at `~/.claude/worktrees/<repo>/issue-<ID>/`
- **Branches**: Named `agent/<IDENTIFIER>` (e.g., `agent/ENG-123`)
- **DB isolation**: Docker containers with random ephemeral ports (postgres or supabase mode)
- **CI gate**: Runs ci-gate before pushing, retries with Claude fix attempts
- **PR workflow**: Creates PRs, posts implementation reports to Linear
- **Feedback resume**: Re-label to resume with PR/Linear feedback
- **Blocking**: Agent writes `.claude/agent-blocked/<ID>.md`, posts to Linear
- **Auto-review**: Spawns read-only Claude to review PRs and post structured reviews
- **Auto-fix**: Iterates review→fix→CI→push cycle up to N times
- **Pipeline**: Parses requirements markdown into Linear issues with dependencies
- **Sequencing**: Filters issues by dependency completion status
- **Guardrails**: Exports CLAUDE_AGENT_MODE=1 for block-destructive.sh hook

### ci-gate
- Reads `.ci-gate` file if present, otherwise auto-detects project type
- Supports: TypeScript/Next.js, Rust, Python, Go
- Exit 0 = safe to push, Exit 1 = stop

### block-destructive.sh
- PreToolUse:Bash hook, only active when CLAUDE_AGENT_MODE=1
- Blocks: rm -rf (except safe dirs), git push --force, git reset --hard, DROP TABLE, chmod 777, curl|bash, dd, mkfs
- Strips quoted strings to avoid false positives

## Conventions

- All scripts use `set -uo pipefail` (not `-e` for agent runner since subshells handle errors)
- Config lives at `~/.config/claude-agents/config.json`
- Secrets at `~/.config/claude-agents/secrets.env` (chmod 600)
- Logs at `~/.config/claude-agents/logs/<workspace>-<identifier>.log`
- Locks at `~/.config/claude-agents/locks/<repo>.lock`
- Worktrees at `~/.claude/worktrees/<repo>/issue-<ID>/` (outside repos to avoid bundler conflicts)

## Editing Guidelines

- When modifying the agent runner: functions are organized by section (Linear API, GitHub, Slack, DB, worktree, review, fix, pipeline, main loop, CLI)
- When modifying ci-gate: each language block is self-contained
- When modifying block-destructive.sh: test with `echo '{"tool_input":{"command":"rm -rf /"}}' | CLAUDE_AGENT_MODE=1 bash hooks/block-destructive.sh`
- setup.sh must remain idempotent — always check before overwriting
