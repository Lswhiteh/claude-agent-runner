# claude-agent-runner: A Linear Walkthrough

> An autonomous Claude agent orchestrator that polls Linear for labeled issues, spawns isolated Claude instances in git worktrees, runs CI, and opens GitHub PRs — all unattended.

---

## The Big Picture

```
┌──────────┐      poll       ┌─────────────────────┐    spawn     ┌──────────────┐
│  Linear   │ ◄──────────── │  claude-agent-runner │ ──────────► │  Claude CLI   │
│  issues   │  GraphQL API   │  (bash orchestrator) │  per issue  │  (worktree)   │
└──────────┘                └─────────────────────┘              └──────┬───────┘
                                │         ▲                            │
                                │         │ CI pass/fail               │ commits
                                ▼         │                            ▼
                           ┌─────────┐  ┌────────┐              ┌──────────┐
                           │  Slack   │  │ci-gate │              │   git    │
                           │  notify  │  │(checks)│              │  push    │
                           └─────────┘  └────────┘              └────┬─────┘
                                                                     │
                                                                     ▼
                                                                ┌──────────┐
                                                                │  GitHub  │
                                                                │  PR      │
                                                                └──────────┘
```

The system turns a labeled Linear issue into a GitHub pull request without human intervention. A cron job (or manual invocation) runs the orchestrator every few minutes, and each issue gets its own isolated environment.

---

## 1. Setup & Configuration

### One-command install

```bash
git clone https://github.com/Lswhiteh/claude-agent-runner.git
cd claude-agent-runner
./setup.sh
```

`setup.sh` is idempotent — safe to re-run. It:

1. **Symlinks scripts** (`bin/`) → `~/.local/bin/` — the main `claude-agent-runner` and `ci-gate` CLI tools
2. **Symlinks hooks** (`hooks/`) → `~/.claude/hooks/` — 11 Claude Code hooks for guardrails, and registers each in `~/.claude/settings.json` under the correct event/matcher
3. **Symlinks skills** (`skills/`) → `~/.claude/skills/` — agent skills like `implement`, `orchestrate`, `debug`, etc.
4. **Creates config** at `~/.config/claude-agents/config.json` from the example template
5. **Creates secrets placeholder** at `~/.config/claude-agents/secrets.env` (chmod 600)
6. **Creates directories** for logs, locks, and traces

### Config structure

```jsonc
// ~/.config/claude-agents/config.json
{
  "label": "Agent",              // Linear label that triggers agent pickup
  "max_parallel": 3,             // Max concurrent agents per team
  "max_turns": 15,               // Claude turns per session (overridden to 500 at invocation)
  "max_ci_retries": 3,           // CI fail → fix → retry attempts
  "max_review_fix_iterations": 3,// Auto-review → fix cycles
  "orchestrator": {
    "enabled": false,            // Enable multi-agent orchestration
    "label": "Orchestrate",      // Label that triggers decomposition
    "max_subtasks": 8,
    "poll_interval_seconds": 30
  },
  "workspaces": {
    "mycompany": {
      "api_key_env": "LINEAR_API_KEY_MYCOMPANY",  // env var name, not the key itself
      "slack_webhook_env": "SLACK_WEBHOOK_MYCOMPANY",
      "teams": {
        "Engineering": {
          "repo": "/path/to/repo",
          "local_db": "postgres"  // or "supabase" or "none"
        }
      }
    }
  }
}
```

Workspaces map to Linear organizations. Each workspace has teams, and each team points to a local git repository. This is how the runner knows _where_ to create worktrees and _which_ Linear API key to use.

### Secrets

```bash
# ~/.config/claude-agents/secrets.env (sourced at startup)
export ANTHROPIC_API_KEY=sk-ant-...
export LINEAR_API_KEY_MYCOMPANY=lin_api_...
export SLACK_WEBHOOK_MYCOMPANY=https://hooks.slack.com/services/...
```

---

## 2. The Polling Loop

The runner is designed to be invoked on a cron schedule (e.g., every 5 minutes):

```cron
*/5 * * * * source ~/.config/claude-agents/secrets.env && claude-agent-runner >> ~/.config/claude-agents/cron.log 2>&1
```

Each invocation:

1. **Iterates workspaces and teams** from `config.json`
2. **Acquires a per-repo lock** (PID-based file lock) to prevent overlapping runs
3. **Cleans up merged worktrees** — removes worktrees whose PR is merged/closed
4. **Counts available slots** — reads `.claude/agent.pid` from existing worktrees, checks which PIDs are still alive, calculates `MAX_PARALLEL - active_count`
5. **Fetches labeled issues** via Linear GraphQL — queries for issues with the configured label (default "Agent"), limited to available slots
6. **For each issue**: spawns a background subprocess to handle it

The key insight: the runner itself is stateless. All state lives in:
- **Worktrees on disk** (is there already a worktree for this issue?)
- **Linear** (issue state, labels, comments)
- **GitHub** (PR existence, review state)
- **JSONL trace files** (observability)

---

## 3. Issue Lifecycle: From Label to PR

When a new issue is picked up, here's the full sequence:

### 3a. Worktree Creation

```
~/.claude/worktrees/<repo-name>/issue-<IDENTIFIER>/
```

The runner:
- `git fetch origin main`
- `git worktree add <path> -b agent/<IDENTIFIER>-<title-slug> origin/main`
- Copies `.env` and `.env.local` from the repo root
- Optionally starts a Docker database container (postgres or supabase) with a random ephemeral port

### 3b. Linear State Update

- Sets the issue state to **"In Progress"**
- **Removes** the agent label (prevents re-pickup on next poll)

### 3c. Claude Invocation

The runner spawns Claude CLI in the worktree:

```bash
export CLAUDE_AGENT_MODE=1          # Enables guardrail hooks
export CLAUDE_AGENT_REPO="myrepo"
export CLAUDE_AGENT_BRANCH="agent/ENG-123-add-auth"
export CLAUDE_AGENT_ISSUE_ID="ENG-123"
export CLAUDE_AGENT_WORKTREE="/path/to/worktree"

claude --permission-mode bypassPermissions \
  --setting-sources project,local \
  -p "You are working in an isolated git worktree for the myrepo project.
Read CLAUDE.md for all project conventions...

## Linear Issue: ENG-123
**Title:** Add user authentication
**Description:** [full issue description from Linear]

## Instructions
- Read CLAUDE.md first
- Use the implement skill
- Write tests before implementation
- Commit atomically with conventional messages
- If blocked, write to .claude/agent-blocked/ENG-123.md and stop
..." \
  --max-turns 500
```

Claude runs autonomously — reading the codebase, writing tests, implementing, committing. The hooks provide guardrails (see Section 6).

### 3d. Post-Claude Checks

After Claude exits, the runner checks three possible outcomes:

**Outcome A: Agent is blocked**
- If `.claude/agent-blocked/ENG-123.md` exists, the agent had questions
- The runner posts the question to Linear as a comment
- Sets issue state back to "Todo"
- Notifies Slack
- Stops — waits for human to respond and re-add the label

**Outcome B: No commits made**
- If `git rev-list --count origin/main..HEAD` is 0, Claude didn't produce anything
- Logs a warning and exits

**Outcome C: Commits exist → CI gate**
- Proceeds to the CI gate (next section)

### 3e. CI Gate

The `ci-gate` tool runs deterministic checks:

```bash
ci-gate /path/to/worktree
```

It auto-detects the project type and runs the appropriate checks:

| Project Type | Checks |
|-------------|--------|
| TypeScript/Next.js | `tsc --noEmit`, vitest/jest, next build |
| Rust | `cargo check`, `cargo test`, `cargo build` |
| Python | pytest |
| Go | `go vet`, `go test`, `go build` |

Projects can also define a `.ci-gate` file with custom commands.

**If CI fails**, the runner enters a retry loop (up to `max_ci_retries`, default 3):
1. Extract the error output
2. Spawn a new Claude session with the errors, asking it to fix them
3. Run CI again
4. Repeat until pass or exhaustion

If all retries fail, the runner posts a CI failure report to Linear and Slack.

### 3f. Push & PR

If CI passes:

1. `git push -u origin agent/ENG-123-add-auth`
2. Create a **draft PR** via `gh pr create`:
   - Title: `ENG-123: Add user authentication`
   - Body: the agent's implementation report (from `.claude/agent-reports/ENG-123.md`) or a default summary
   - Footer: "Closes ENG-123"
3. Update Linear state to **"In Review"**
4. Post a success comment to Linear with the PR link
5. Notify Slack

---

## 4. Auto-Review & Auto-Fix

When invoked with `--auto-review` or `--auto-fix`, the runner adds automated code review after PR creation.

### Auto-Review

A separate Claude instance (in read-only `--permission-mode plan`) reviews the PR diff and outputs structured JSON:

```json
{
  "verdict": "approve | request_changes | comment",
  "summary": "...",
  "blocking": ["Critical issue 1", "..."],
  "important": ["Suggestion 1", "..."],
  "nits": ["Minor style thing", "..."],
  "praise": ["Nice use of...", "..."]
}
```

The review is posted to GitHub via `gh pr review` with the appropriate verdict.

### Auto-Fix Loop

If `--auto-fix` is enabled and the review verdict is `request_changes`:

1. Gather all PR feedback (top-level comments, review bodies, inline file comments)
2. Spawn a Claude agent in the worktree to address the feedback
3. Run CI gate on the fixes
4. Push and re-review
5. Repeat up to `max_review_fix_iterations` (default 3) or until approved

---

## 5. Feedback Resume

The system supports iterative human-in-the-loop feedback without starting over.

### How it works

1. A human reviews the PR or adds comments on the Linear issue
2. The human re-adds the "Agent" label to the issue
3. On the next poll, the runner detects the **existing worktree** and enters resume mode
4. It gathers all feedback (PR comments, review comments, Linear comments)
5. It spawns Claude with the `-r` flag to **resume the previous session**, passing the new feedback as context

This means Claude retains its full conversation history from the previous run — it knows what it already did, what was attempted, etc.

Two resume flavors:
- **Blocked resume**: Agent had asked a question → developer answered → agent continues with the answer
- **Feedback resume**: PR got review comments → agent addresses each one with new commits

---

## 6. Guardrail Hooks

The hooks activate via environment variables, so they only enforce rules during autonomous agent runs — not during interactive Claude Code sessions.

| Hook | Event | Gate | Purpose |
|------|-------|------|---------|
| `block-destructive.sh` | PreToolUse:Bash | `CLAUDE_AGENT_MODE=1` | Blocks `rm -rf`, `git push --force`, `DROP TABLE`, `curl\|bash`, etc. |
| `scope-guard.sh` | PreToolUse:Bash | `CLAUDE_AGENT_SCOPED=1` | Enforces file-write scope for orchestrated subtasks |
| `command-budget.sh` | PreToolUse:Bash | `CLAUDE_AGENT_MODE=1` | Denies after N bash commands (default 300) per session |
| `command-rewriter.sh` | PreToolUse:Bash | `CLAUDE_AGENT_MODE=1` | Adds `--save-exact` to `npm install` |
| `auto-lint.sh` | PostToolUse:Edit\|Write | `CLAUDE_AGENT_MODE=1` | Async linting on file saves (eslint/ruff) |
| `rtk-failure-hint.sh` | PostToolUseFailure:Bash | _(always)_ | Suggests `rtk proxy` when RTK commands fail |
| `session-context.sh` | SessionStart | `CLAUDE_AGENT_MODE=1` | Injects agent identity (issue ID, repo, branch) |
| `stop-gate.sh` | Stop | `CLAUDE_AGENT_MODE=1` | Blocks Claude from finishing if no test evidence in transcript |
| `task-validator.sh` | TaskCompleted | `CLAUDE_AGENT_MODE=1` | Blocks task completion without test evidence |
| `subagent-collector.sh` | SubagentStop | `CLAUDE_AGENT_SCOPED=1` | Logs subagent results to JSONL |
| `pre-compact.sh` | PreCompact | `CLAUDE_AGENT_MODE=1` | Saves git state snapshot before context compaction |

The `stop-gate` and `task-validator` hooks are particularly important — they parse the Claude transcript looking for evidence that tests were actually run (matching patterns like `vitest`, `pytest`, `cargo test`, etc.), preventing agents from claiming "done" without testing.

---

## 7. Orchestration (Multi-Agent)

For complex issues that span multiple files/concerns, the orchestrator decomposes work into scoped subtasks and supervises parallel agents.

### Trigger

An issue with both the "Agent" _and_ "Orchestrate" labels.

### 5-Phase Process

**Phase 1: Decomposition**
A Claude instance analyzes the issue and the codebase, then writes subtask JSON files:

```json
// .claude/orchestrator/subtask-001.json
{
  "id": "ST-1",
  "title": "Add auth middleware",
  "skill": "backend",
  "scope": ["src/middleware/auth.ts", "src/lib/jwt.ts"],
  "off_limits": ["src/db/*"],
  "shared_files": ["src/types.ts"],
  "acceptance_criteria": "JWT validation middleware with tests",
  "depends_on": []
}
```

If the orchestrator decides the issue is single-concern, it writes a `no_decomposition.json` and the runner falls back to a standard single-agent flow.

**Phase 2: Linear Sub-Issue Creation**
For each subtask file:
- Creates a child issue in Linear under the parent
- Adds the agent label (so workers pick them up)
- Creates `isBlockedBy` relations for dependency ordering
- Posts a summary comment on the parent issue

**Phase 3: Supervisor Polling**
The orchestrator polls Linear every 30 seconds, checking if subtask issues have been moved to "completed" state by their respective workers. This continues until all subtasks are done.

**Phase 4: Integration Validation**
Once all subtasks complete:
- Pull all changes into the parent branch
- Run CI gate on the integrated result
- If CI fails: spawn a fix agent, retry (up to `max_validation_retries`)

**Phase 5: Combined PR**
- Push the integrated branch
- Create a PR with a combined report from all subtask implementation reports
- Update Linear, notify Slack

### Scoped Workers

Subtask issues are picked up by the normal polling loop but detected as children of an orchestrated parent. They run with additional constraints:

```bash
export CLAUDE_AGENT_SCOPED=1
export CLAUDE_AGENT_SCOPE_FILE=".claude/orchestrator/active-scope.json"
```

The `scope-guard.sh` hook reads the scope file and **blocks any file writes outside the allowed paths**. Workers can read anything but can only write to their assigned files. If they need to touch files outside their scope, they write a scope-overflow document instead of making the change.

---

## 8. Pipeline: Requirements → Linear Issues

The `--pipeline` command turns a requirements markdown document into Linear issues with dependency relations.

```bash
claude-agent-runner --pipeline requirements.md --workspace mycompany --team Engineering
```

Flow:
1. Claude parses the markdown into a structured JSON array of stories (title, description, estimate, labels, dependencies)
2. Each story becomes a Linear issue with the agent label
3. Dependencies between stories become `isBlockedBy` relations in Linear
4. With `--sequenced`, dependent stories don't get the agent label until their blockers complete

### Dry run

```bash
claude-agent-runner --pipeline requirements.md --dry-run
```

Prints the parsed stories without creating anything — useful for validating the parse.

---

## 9. Spec Generation: Idea → Requirements

The `--spec` command generates structured requirements from a freeform idea:

```bash
# Generate and print spec
claude-agent-runner --spec idea.md --workspace mycompany --team Engineering

# Interactive mode — ask Claude clarifying questions
claude-agent-runner --spec idea.md --interactive

# Generate spec AND create Linear issues in one shot
claude-agent-runner --spec idea.md --create
```

The spec generator reads the project's `CLAUDE.md` for context, so generated stories are aware of the codebase's conventions, stack, and architecture.

The `--create` flag chains directly into `--pipeline`, so `--spec idea.md --create` goes from idea → structured spec → Linear issues in one command.

---

## 10. Observability

### JSONL Event Traces

Every issue run emits structured events to `~/.config/claude-agents/traces/<workspace>-<identifier>.jsonl`:

```jsonl
{"event":"issue.started","ts":"2026-03-12T10:00:00Z","run_id":"ENG-123-1710244800","identifier":"ENG-123","title":"Add auth"}
{"event":"worktree.created","ts":"...","path":"/Users/..."}
{"event":"agent.started","ts":"...","mode":"standard"}
{"event":"ci.passed","ts":"...","attempt":1}
{"event":"pr.created","ts":"...","url":"https://github.com/..."}
```

~30 event types across 7 categories: issue, agent, orchestration, CI, PR, review, cleanup.

### agent-trace CLI

```bash
agent-trace list                    # List all traces
agent-trace show ENG-123            # Pretty-print a trace
agent-trace tail ENG-123            # Live-tail (like tail -f)
agent-trace view                    # Open browser timeline viewer
agent-trace view ENG-123            # Open viewer filtered to one trace
```

### Timeline Viewer

`agent-trace view` launches a single-file HTML viewer (`agent-trace-viewer.html`) with:
- Dark sidebar listing all trace files
- Color-coded vertical timeline of events
- Filter chips by event category
- Search input
- Auto-refresh toggle (5-second polling)
- Swimlane view for orchestrated issues (shows subtask timelines side-by-side)

### Logs

Per-issue logs at `~/.config/claude-agents/logs/<workspace>-<identifier>.log` capture full stdout/stderr from each agent run.

### Slack

Real-time notifications at key lifecycle points: agent started, blocked, feedback addressed, PR created, CI failed, orchestrator completed.

### --status

```bash
claude-agent-runner --status
```

Shows active agents, their PIDs, which issues they're working on, and pending issue counts per team.

---

## 11. Utility Commands

```bash
# Clean up worktrees for merged/closed PRs
claude-agent-runner --cleanup

# Standalone PR review (no agent run)
claude-agent-runner --review-pr 42 --repo /path/to/repo

# Show help
claude-agent-runner --help
```

---

## 12. Skills

The project ships Claude Code skills that agents invoke during their work. These are structured prompts that guide Claude through specific workflows:

| Skill | Purpose |
|-------|---------|
| `implement` | Full feature workflow: plan → tests → code → validate |
| `orchestrate` | Decompose a multi-concern issue into scoped subtasks |
| `scoped-worker` | Scope-aware implementation for orchestrated subtasks |
| `ci-fix` | Diagnose and fix CI failures |
| `debug` | Systematic debugging: reproduce → isolate → fix → regression test |
| `spec-writer` | Transform ideas into structured development requirements |
| `review-pr` | Structured PR review |
| `agent-report` | Generate implementation summary |
| `blocked` | File a blocking question |
| `backend` | Backend implementation guidance |
| `frontend` | Frontend implementation guidance |
| `data-flow` | Trace data flow across the stack |
| `simplify` | Review code for over-engineering and dead code |

---

## Putting It All Together

A typical autonomous workflow:

```
1. Developer writes a Linear issue: "Add dark mode toggle to settings page"
2. Developer adds the "Agent" label

3. Cron fires → claude-agent-runner polls Linear → finds the issue
4. Creates worktree at ~/.claude/worktrees/myapp/issue-ENG-456/
5. Starts Postgres container on random port
6. Spawns Claude with the issue description

7. Claude reads CLAUDE.md, explores codebase
8. Writes failing tests for dark mode toggle
9. Implements the feature
10. Commits atomically: "feat: add dark mode toggle to settings"

11. Claude exits → runner checks for blocked file → none
12. Runner runs ci-gate → tsc, vitest, next build → pass
13. Runner pushes branch, creates draft PR
14. Posts to Linear: "✅ Agent completed — PR: github.com/org/myapp/pull/87"
15. Notifies Slack

16. [Optional] Auto-review catches a missing aria-label
17. Auto-fix agent adds the attribute, pushes, re-reviews → approved

18. Developer reviews the PR, merges
19. Next cleanup cycle removes the worktree
```

If the agent gets stuck at step 9 — say it needs to know which color palette to use — it writes a blocked file, the runner posts the question to Linear, and the developer just answers in the comments and re-labels. The agent picks up right where it left off.
