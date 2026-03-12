# claude-agent-runner

Autonomous Claude agent orchestrator that polls Linear for labeled issues, spawns isolated Claude instances in git worktrees, runs CI, and opens GitHub PRs.

## Project Structure

```
bin/
  claude-agent-runner       Main orchestrator script
  ci-gate                   Deterministic CI checks before push
  agent-trace               CLI for querying JSONL event traces (list, show, tail, view)
  agent-trace-viewer.html   Single-file HTML viewer for trace timelines

hooks/
  block-destructive.sh      PreToolUse:Bash — blocks rm -rf, force-push, etc. (CLAUDE_AGENT_MODE=1)
  scope-guard.sh            PreToolUse:Bash — enforces file scope (CLAUDE_AGENT_SCOPED=1)
  command-budget.sh         PreToolUse:Bash — denies after N commands (CLAUDE_AGENT_MODE=1)
  command-rewriter.sh       PreToolUse:Bash — adds --save-exact to npm install (CLAUDE_AGENT_MODE=1)
  auto-lint.sh              PostToolUse:Edit|Write — async linting on file changes (CLAUDE_AGENT_MODE=1)
  rtk-failure-hint.sh       PostToolUseFailure:Bash — suggests rtk proxy on failure
  session-context.sh        SessionStart — injects agent identity context (CLAUDE_AGENT_MODE=1)
  stop-gate.sh              Stop — blocks finish if no test evidence (CLAUDE_AGENT_MODE=1)
  subagent-collector.sh     SubagentStop — logs subagent results (CLAUDE_AGENT_SCOPED=1)
  task-validator.sh         TaskCompleted — blocks task completion without tests (CLAUDE_AGENT_MODE=1)
  pre-compact.sh            PreCompact — saves git state snapshot (CLAUDE_AGENT_MODE=1)

skills/                     Claude Code skills for agent use
  agent-report/             Implementation summary generation
  backend/                  Backend implementation guidance
  blocked/                  Blocked-question filing
  ci-fix/                   CI failure resolution
  data-flow/                Data flow analysis
  debug/                    Debugging guidance
  frontend/                 Frontend implementation guidance
  implement/                Feature implementation workflow
  orchestrate/              Task decomposition for multi-agent orchestration
  review-pr/                PR review guidance
  scoped-worker/            Scope-aware worker for orchestrated subtasks
  simplify/                 Code simplification
  spec-writer/              Idea-to-spec generation

config/
  config.example.json       Config template with all fields documented

setup.sh                    One-command install: symlinks, hooks, skills, config
```

## Key Architecture

### Agent Runner (~2450 lines bash)
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
- **Spec generation**: `--spec` turns free-form ideas into structured requirements
- **Sequencing**: Filters issues by dependency completion status
- **Orchestration**: Decomposes issues with "Orchestrate" label into scoped sub-issues, supervises workers, runs integration validation, creates combined PR
- **Scoped workers**: Sub-issues of orchestrated parents run with file scope enforcement via scope-guard hook
- **Guardrails**: Exports CLAUDE_AGENT_MODE=1 for block-destructive.sh; CLAUDE_AGENT_SCOPED=1 for scope-guard.sh
- **Agent identity**: Exports CLAUDE_AGENT_ISSUE_ID, CLAUDE_AGENT_REPO, CLAUDE_AGENT_BRANCH, CLAUDE_AGENT_WORKTREE at all claude invocation sites
- **Event tracing**: JSONL event traces at `~/.config/claude-agents/traces/` — one file per issue, ~30 events across 7 categories (issue, agent, orchestration, CI, PR, review, cleanup)
- **Note**: `orchestrator.auto` is loaded from config but currently unused (dead field)

### ci-gate
- Reads `.ci-gate` file if present, otherwise auto-detects project type
- Supports: TypeScript/Next.js, Rust, Python, Go
- Exit 0 = safe to push, Exit 1 = stop

### block-destructive.sh
- PreToolUse:Bash hook, only active when CLAUDE_AGENT_MODE=1
- Blocks: rm -rf (except safe dirs), git push --force, git reset --hard, DROP TABLE, chmod 777, curl|bash, dd, mkfs
- Strips quoted strings to avoid false positives

### scope-guard.sh
- PreToolUse:Bash hook, only active when CLAUDE_AGENT_SCOPED=1
- Reads allowed file scope from $CLAUDE_AGENT_SCOPE_FILE (subtask JSON)
- Blocks writes (redirect, sed -i, tee) outside scope
- Allows reads anywhere, always allows writes to `.claude/orchestrator/`, `.claude/agent-reports/`, `.claude/agent-blocked/`
- Test: `echo '{"tool_input":{"command":"echo > bad.ts"}}' | CLAUDE_AGENT_SCOPED=1 CLAUDE_AGENT_SCOPE_FILE=subtask.json bash hooks/scope-guard.sh`

### command-budget.sh
- PreToolUse:Bash hook, only active when CLAUDE_AGENT_MODE=1
- Tracks Bash calls per session via counter file at `/tmp/claude-agent-budget-<session_id>`
- Denies at threshold (default 300, override with $CLAUDE_AGENT_CMD_BUDGET)

### command-rewriter.sh
- PreToolUse:Bash hook, only active when CLAUDE_AGENT_MODE=1
- Rewrites `npm install <packages>` to include `--save-exact`
- Skips bare `npm install`, `npm ci`, and commands that already have `--save-exact`

### auto-lint.sh
- PostToolUse:Edit|Write hook (async), only active when CLAUDE_AGENT_MODE=1
- Runs eslint (ts/js) or ruff (py) on edited files
- Non-blocking: output delivered as context on next turn

### rtk-failure-hint.sh
- PostToolUseFailure:Bash hook, no gate (useful everywhere)
- When `rtk <cmd>` fails, suggests re-running with `rtk proxy <cmd>`

### session-context.sh
- SessionStart hook, only active when CLAUDE_AGENT_MODE=1
- Reads CLAUDE_AGENT_ISSUE_ID, CLAUDE_AGENT_REPO, CLAUDE_AGENT_BRANCH, CLAUDE_AGENT_WORKTREE
- Outputs agent identity as additionalContext
- Persists env vars to $CLAUDE_ENV_FILE if available

### stop-gate.sh
- Stop hook, only active when CLAUDE_AGENT_MODE=1
- Parses transcript for CI/test evidence (ci-gate, npm test, pytest, cargo test, vitest, jest, go test)
- Blocks stop if no test evidence found
- Uses CLAUDE_STOP_HOOK_ACTIVE guard to prevent infinite loops

### task-validator.sh
- TaskCompleted hook, only active when CLAUDE_AGENT_MODE=1
- Same transcript parsing as stop-gate
- Exit 2 + stderr to block task completion without test evidence

### subagent-collector.sh
- SubagentStop hook, only active when CLAUDE_AGENT_SCOPED=1
- Appends JSONL entries to `.claude/orchestrator/subagent-log.jsonl`
- Pure logging, no blocking

### pre-compact.sh
- PreCompact hook, only active when CLAUDE_AGENT_MODE=1
- Saves git state snapshot to `.claude/agent-state/compact-snapshot-<timestamp>.md`
- Non-blocking (PreCompact cannot prevent compaction)

### agent-trace
- CLI tool for querying JSONL event traces
- Subcommands: `list` (all traces), `show <id>` (pretty-print), `tail <id>` (live-tail), `view [id]` (browser viewer)
- `view` copies viewer HTML into traces dir, starts `python3 -m http.server 7842`, opens browser

### agent-trace-viewer.html
- Single-file HTML viewer (no build step, no CDN, no framework)
- Dark sidebar listing trace files; main area with color-coded vertical timeline
- Filter chips by category, search input, auto-refresh toggle (5s polling)
- Swimlane view auto-activates when orchestration/subtask events are present

## Conventions

- All scripts use `set -uo pipefail` (not `-e` for agent runner since subshells handle errors)
- Config lives at `~/.config/claude-agents/config.json`
- Secrets at `~/.config/claude-agents/secrets.env` (chmod 600)
- Logs at `~/.config/claude-agents/logs/<workspace>-<identifier>.log`
- Traces at `~/.config/claude-agents/traces/<workspace>-<identifier>.jsonl`
- Locks at `~/.config/claude-agents/locks/<repo>.lock`
- Worktrees at `~/.claude/worktrees/<repo>/issue-<ID>/` (outside repos to avoid bundler conflicts)

## Editing Guidelines

- When modifying the agent runner: functions are organized by section (Linear API, GitHub, Slack, DB, worktree, review, fix, orchestrator, pipeline, spec, main loop, CLI)
- When modifying ci-gate: each language block is self-contained
- When modifying hooks: test with `echo '<JSON>' | ENV_VAR=1 bash hooks/<hook>.sh` (see each hook's header for test command)
- All hooks use the gate pattern: check env var, exit 0 early if inactive
- setup.sh must remain idempotent — always check before overwriting
- Orchestration detection uses Linear labels (not description markers) — `Orchestrate` label triggers decomposition, `parent.id` field identifies subtasks

## Documentation

- [docs/walkthrough.md](docs/walkthrough.md) — full linear narrative of every flow
- [docs/walkthrough-slides.html](docs/walkthrough-slides.html) — 20-slide HTML presentation (open in browser, no dependencies)
