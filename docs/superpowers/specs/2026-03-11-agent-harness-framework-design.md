# Agent Harness Framework — Design Spec

**Date:** 2026-03-11
**Status:** Draft
**Scope:** Generalizable enforcement layer, interactive dispatch mode, validation instrumentation

## Problem

The claude-agent-runner has strong autonomous capabilities (worktree isolation, CI gating, Linear integration, orchestration), but the enforcement and feedback mechanisms are hardcoded as individual hooks with no per-project configurability. There's no interactive mode — the only entry point is Linear polling. And there's no systematic way to measure whether the guardrails are actually improving agent output quality.

Three gaps:

1. **Enforcement is not configurable.** Hooks like `block-destructive.sh` and `stop-gate.sh` are general-purpose but can't be tuned per-project. There's no way for a project to declare "enforce service layer boundaries" or "block direct env access outside config" without writing custom hooks.

2. **No interactive mode.** Developers must create a Linear issue and wait for the poller. There's no way to invoke the runner's infrastructure (worktree setup, hooks, CI gate, PR creation) from within a Claude Code session.

3. **No validation loop.** The tracer logs events but doesn't track enforcement effectiveness — rule fire rates, self-correction rates, false positives, impact on CI pass rates or review rounds.

## Design Principles

- **Constraints > instructions.** Deterministic enforcement (hooks) over advisory guidance (CLAUDE.md). CLAUDE.md says what to do; hooks ensure it happens.
- **Cheapest tool that works.** Grep before AST, AST before LLM. Each level adds cost and nondeterminism.
- **Linear is the spine.** Both autonomous and interactive modes use Linear for tracking. The CLI wrapper makes this token-efficient.
- **Repo owns enforcement.** Rules live in the repo, not in Linear or external config. Version-controlled, auditable, PR-reviewable.
- **Measure the system.** Every enforcement action is traced. The harness validates its own effectiveness.

## Architecture Overview

```
+-----------------------------------------------------+
|                    TRIGGER LAYER                     |
|                                                      |
|   Autonomous (poll)          Interactive (skill)     |
|   +---------------+         +-------------------+   |
|   | Linear poll   |         | /dispatch ENG-123 |   |
|   | labeled       |         | /dispatch "idea"  |   |
|   | issues        |         |                   |   |
|   +-------+-------+         +---------+---------+   |
|           |                           |              |
|           +-----------+---------------+              |
|                       v                              |
|            +------------------+                      |
|            |   linear-cli     |  (schpet/linear-cli) |
|            |   create / read  |                      |
|            |   update / comment|                     |
|            +--------+---------+                      |
+-----------------------+-------------------------------+
                        v
+-------------------------------------------------------+
|                  EXECUTION LAYER                       |
|                                                        |
|   +-------------+  +--------------+  +---------------+ |
|   |  Worktree   |  |   Docker     |  |    Claude     | |
|   |  isolation   |  |  isolation   |  |   session(s)  | |
|   +-------------+  +--------------+  +---------------+ |
+-------------------------------------------------------+
                        v
+-------------------------------------------------------+
|                ENFORCEMENT LAYER                       |
|         (generalizable harness)                        |
|                                                        |
|   Per-project config:  .claude/enforcement.yaml        |
|                                                        |
|   +-----------+  +-----------+  +-------------------+  |
|   |   BLOCK   |  |   WARN    |  |      INFO         |  |
|   |           |  |           |  |                    |  |
|   | rm -rf    |  | pattern   |  | telemetry          |  |
|   | force push|  | violation |  | style drift        |  |
|   | no tests  |  | wrong     |  | unused pattern     |  |
|   | raw SQL   |  | layer     |  |                    |  |
|   +-----------+  +-----------+  +-------------------+  |
|                                                        |
|   Built-in (general):      Project rules (per-repo):   |
|   - block-destructive      - .claude/enforcement.yaml  |
|   - stop-gate              - .claude/patterns/*.md     |
|   - command-budget         - feature-level CLAUDE.md   |
|   - scope-guard            - .claude/orchestrator/     |
+-------------------------------------------------------+
                        v
+-------------------------------------------------------+
|              VALIDATION & TRACING                      |
|                                                        |
|   +-----------------------------------------------+   |
|   |              Event Trace (JSONL)               |   |
|   |                                                |   |
|   |  issue.*  agent.*  enforcement.*  ci.*         |   |
|   |  pr.*     review.*  orchestration.*  cleanup.* |   |
|   +-------------------------+---------------------+   |
|                             v                          |
|   +-----------------------------------------------+   |
|   |           Metrics / Dashboard                  |   |
|   |                                                |   |
|   |  - Rule fire rate (block/warn/info)            |   |
|   |  - Self-correction rate (warn -> agent fixed)  |   |
|   |  - CI pass rate (first push)                   |   |
|   |  - Time-to-merge                               |   |
|   |  - False positive rate (human overrides)       |   |
|   +-----------------------------------------------+   |
+-------------------------------------------------------+
```

## Component 1: Enforcement Layer

### Hook Structure

Two new hooks sharing a library, plus the existing hooks which become "built-in rules":

```
hooks/
  enforce-pre.sh      # PreToolUse:Edit,Write — synchronous, can block
  enforce-post.sh     # PostToolUse:Edit,Write — async, injects context
  enforce-lib.sh      # shared: YAML parsing, rule matching, check runners
```

**`enforce-pre.sh`** — fires before Edit/Write actions. Evaluates only `block`-level rules using deterministic checks (grep, biome). If any fire, exits with code 2 and a violation message. The agent sees the block and self-corrects.

**`enforce-post.sh`** — fires after Edit/Write actions complete. Evaluates `warn` and `info` rules across all check types, including LLM. Outputs violations as `additionalContext` for warn-level. Appends info-level to `.claude/enforcement.log`. Emits trace events.

**First iteration scope:** Only enforce on Edit and Write tools where the file path is explicit. Bash-level enforcement stays in existing hooks (`block-destructive.sh`, `scope-guard.sh`). Bash commands are too varied to reliably determine affected files.

### Check Types

Three tiers, escalate only when needed:

**1. Grep (pattern matching)**
- Near-zero cost, instant execution
- Good for: import restrictions, banned function calls, env access patterns, logging statements
- Runs in both pre and post hooks

**2. Biome / linter (AST-aware)**
- Structural code analysis, understands syntax not just text
- Good for: export style, nesting depth, hook call rules, naming conventions
- Runs in both pre and post hooks
- Uses whatever linter the project already has configured (biome, eslint, ruff)

**3. LLM-judged (Haiku)**
- Semantic understanding of code intent and architecture
- Good for: layer boundary violations, single responsibility, architectural fit
- Runs in post hook only (async) — too slow for blocking
- Calls Anthropic API directly via `curl`
- 3-second timeout — skip gracefully if API is slow
- Cost: ~$0.0004 per check (1K tokens in, 100 tokens out)
- Caches results by file content hash — skips re-check if file unchanged since last evaluation

### Enforcement Levels

**`block`** — Hook exits non-zero (code 2). Action is denied. Agent sees the error message and must self-correct before proceeding. Only for deterministic checks (grep, biome) — never LLM, since nondeterministic blocks would be frustrating.

**`warn`** — Action proceeds. Violation message injected as context on the agent's next turn via stdout. Agent is expected to self-correct. If it doesn't, the violation is logged and visible in traces.

**`info`** — Action proceeds silently. Violation appended to `.claude/enforcement.log`. Available for auditing and metrics but doesn't pollute agent context. Useful for tracking style drift over time.

### enforcement.yaml Schema

Location: `.claude/enforcement.yaml` in the project root.

```yaml
version: 1

# Override built-in hook behavior
builtins:
  command-budget: 500              # override default 300
  block-destructive: true          # true | false
  stop-gate: block                 # block | warn | off
  scope-guard: true                # true | false
  # Mechanism: built-in hooks source enforce-lib.sh and call
  # enforce_builtin_level "stop-gate" to read their override.
  # Returns "block"|"warn"|"off". Each hook adjusts behavior accordingly.

# Global settings for the enforcement system
settings:
  llm:
    model: claude-haiku-4-5-20251001
    api_key_env: ANTHROPIC_API_KEY   # env var name, never the key itself
    max_tokens: 200
    timeout: 5                       # seconds — skip check if exceeded (configurable per-project)
  cache_ttl: 300                     # seconds to cache parsed config
  trace: true                        # emit enforcement.* trace events
  log_file: ~/.config/claude-agents/logs/enforcement.log  # outside project tree to avoid git noise

  # Rule auto-updating settings
  auto_evolve:
    auto_escalate:
      enabled: true
      threshold: 5                   # consecutive self-corrections before proposing escalation
      cooldown: 7d                   # don't re-evaluate for 7 days after escalation
      auto_apply: false              # true = apply without prompting (autonomous mode default)
    check_downgrade:
      enabled: false                 # v2 — LLM-to-deterministic conversion (requires meta-analysis)
    guidance_suggest:
      enabled: false                 # v2 — CLAUDE.md injection suggestions (requires cross-session data)

rules:
  # Each rule requires: name, description, check, level
  # Optional: files, exclude, pattern, rule, prompt, phase

  - name: <identifier>               # unique, kebab-case
    description: "<why this rule exists>"
    check: grep | biome | llm
    level: block | warn | info

    # For grep checks:
    pattern: "<regex>"

    # For biome checks:
    rule: "<biome-rule-name>"

    # For llm checks:
    prompt: |
      <prompt text sent to Haiku along with the file diff>

    # File targeting (all check types):
    files: "glob/pattern/**/*.ts"    # which files this rule applies to
    exclude: "**/*.test.ts"          # files to skip

    # Orchestration (optional):
    phase: integration               # only runs during parent integration check
```

### Nested Ticket Enforcement

Child issues inherit repo-level enforcement rules naturally — rules match by file glob, and scope-guard limits which files each child can touch. A child working in `src/routes/dashboard/*` only triggers rules with matching file globs.

Parent-level integration rules live in `.claude/orchestrator/<ISSUE-ID>/enforcement.yaml` with `phase: integration`. These run only during the parent's integration validation after all children complete.

**Lifecycle:** Integration enforcement files are created by the orchestrator during issue decomposition and cleaned up when the parent PR is merged. The autonomous runner's cleanup phase already removes `.claude/orchestrator/<ID>/` directories; dispatch mode should do the same on PR merge.

```
.claude/
  enforcement.yaml                           # repo-wide rules
  orchestrator/
    ENG-100/
      enforcement.yaml                       # integration-phase rules for ENG-100
```

### YAML Parsing

Use `yq` to convert enforcement.yaml to JSON once, then query with `jq` at invocation time. This is consistent with the existing codebase which already uses `jq` heavily.

```bash
# On first invocation (or when config mtime changes):
yq -o json .claude/enforcement.yaml > /tmp/enforce-<config-hash>.json

# Per-rule queries at hook time:
jq -r '.rules[] | select(.level == "block") | select(.files | test("src/routes"))' \
  /tmp/enforce-<config-hash>.json
```

Cache the JSON in `/tmp/enforce-<config-hash>.json`. Invalidate when the config file's mtime changes. This avoids the fragility of flattening YAML arrays-of-objects into shell variables.

### Rule Auto-Evolution

Rules should tighten and cheapen over time as the system observes patterns. Three mechanisms, in order of automation maturity:

**The progression:**

```
LLM warn (expensive, catches everything)
    |  pattern stabilizes
    v
grep/biome warn (cheap, deterministic)
    |  agent always self-corrects
    v
grep/biome block (prevent it entirely)
    +  CLAUDE.md guidance (prevent agent from even trying)
```

Rules start expensive and permissive, then naturally tighten and cheapen as the system learns.

#### v1: Auto-Escalation (fully automatic)

When `agent-harness status` detects a `warn` rule has been self-corrected N times consecutively with zero overrides, it proposes escalation to `block`.

**Trigger:** N consecutive `self_corrected` events for the same rule with zero `override` events in between (default N=5, configurable via `settings.auto_evolve.auto_escalate.threshold`).

**Behavior by mode:**
- **Interactive (dispatch):** prompts the developer — "Rule `no-console-log` has been self-corrected 8/8 times. Escalate to `block`? [y/n]"
- **Autonomous (runner):** if `auto_apply: true`, modifies enforcement.yaml directly and commits the change. If `false`, logs the recommendation.

**Safety:** Only escalates `warn → block`. Never auto-escalates `info → warn` (that would increase context noise without developer consent). Cooldown period prevents re-evaluation thrash.

**Trace events:**
```jsonl
{"ts":"...","cat":"enforcement","event":"rule.escalated","rule":"no-console-log","from":"warn","to":"block","reason":"8/8 self-corrected, 0 overrides","auto":true}
```

#### v2: Check-Type Downgrade (semi-automatic)

When an LLM rule consistently fires on structurally similar code, Haiku analyzes its own violation history and proposes a deterministic replacement.

**Trigger:** An LLM rule fires 5+ times and the violations show a recognizable pattern.

**Process:**
1. `agent-harness` collects recent violations for the rule (file, line, code snippet)
2. Sends them to Haiku with the prompt: "You've flagged these N violations. Can this be expressed as a grep pattern or biome rule instead of an LLM check?"
3. If Haiku produces a pattern, the system proposes adding a grep/biome rule and optionally retiring the LLM rule

**Output example:**
```yaml
# AUTO-GENERATED from LLM rule "service-layer-boundary"
# Based on 6 consistent violations (2026-03-01 to 2026-03-11)
- name: no-prisma-in-routes
  description: "Direct Prisma calls in route handlers — use service layer"
  check: grep
  pattern: "prisma\\.\\w+\\.\\w+\\("
  files: "src/routes/**/*.ts"
  level: warn
  derived_from: service-layer-boundary   # lineage tracking
```

**Safety:** Always proposes, never auto-applies. The developer reviews and merges. The original LLM rule can remain as a catch-all for violations the grep pattern misses.

**Trace events:**
```jsonl
{"ts":"...","cat":"enforcement","event":"rule.downgraded","rule":"service-boundary","from":"llm","to":"grep","new_pattern":"prisma\\.\\w+","proposed":true}
```

#### v2/v3: CLAUDE.md Guidance Injection (preventive)

When a rule fires repeatedly across multiple sessions, the system suggests adding guidance to the relevant feature-level CLAUDE.md so agents avoid the violation entirely.

**Trigger:** A rule fires N+ times across M+ distinct sessions (thresholds TBD, likely 10+ fires across 5+ sessions).

**Process:**
1. `agent-harness status` identifies high-frequency rules
2. Determines the most specific CLAUDE.md location (e.g., `src/routes/CLAUDE.md` for a routes-scoped rule)
3. Proposes guidance text:

```
Rule "no-prisma-in-routes" has fired 14 times across 6 sessions.
Suggest adding to src/routes/CLAUDE.md:

  "Route handlers must not call Prisma directly.
   Import from src/services/ instead. See src/services/user-service.ts
   for the pattern."
```

**Safety:** Suggestion only — never auto-modifies CLAUDE.md files. These are developer-authored guidance and should stay under human control.

**Trace events:**
```jsonl
{"ts":"...","cat":"enforcement","event":"guidance.suggested","rule":"no-prisma-in-routes","target":"src/routes/CLAUDE.md","fires":14,"sessions":6}
```

#### Evolution Lifecycle Summary

| Phase | Mechanism | Automation | Version |
|---|---|---|---|
| Detect | LLM-judged rule fires as `warn` | Automatic | v1 |
| Tighten | Auto-escalate `warn → block` after consistent self-correction | Auto (with opt-in) | v1 |
| Cheapen | Downgrade LLM check to grep/biome | Proposed, human applies | v2 |
| Prevent | Suggest CLAUDE.md guidance to avoid violations entirely | Proposed, human applies | v2/v3 |

### Pre-Hook Grep Targets

In `enforce-pre.sh`, the file has not been modified yet. The grep target depends on the tool:

- **Edit operations:** grep against `tool_input.new_string` (the incoming content). The hook receives tool input as JSON on stdin.
- **Write operations:** grep against `tool_input.content` (the full file content being written).

In `enforce-post.sh`, the file exists on disk, so grep runs against the actual file. This distinction is important — pre-hooks check what's about to be written, post-hooks check what was written.

## Component 2: `agent-harness` CLI

Location: `bin/agent-harness`

### Subcommands

**`agent-harness init`**
Bootstraps `.claude/enforcement.yaml` for a project.

1. Detect stack — reuse `ci-gate`'s language/framework detection logic
2. Scan for existing linters — check for `biome.json`, `.eslintrc*`, `ruff.toml`, `pyproject.toml`, `.golangci.yml`
3. Scan directory structure — identify layer patterns (`routes/`, `services/`, `components/`, `lib/`, `db/`)
4. Generate baseline `.claude/enforcement.yaml` from deterministic scans (steps 1-3) — grep rules from detected patterns, biome rules from existing linter config
5. Call Haiku (if API key available) — send directory tree + sample of key files, ask it to identify architectural patterns, layer boundaries, and suggest additional LLM-judged rules. If the API call fails or no key is configured, skip gracefully — the deterministic rules from step 4 are still useful on their own.
6. Merge LLM suggestions into the enforcement.yaml
7. Generate `.claude/patterns/` directory with markdown docs explaining each rule's rationale
8. Print summary, remind developer to review before activating

**`agent-harness check [file|dir]`**
Run enforcement rules manually against specified files.

```
$ agent-harness check src/routes/users.ts

  BLOCK  no-env-access         line 12: process.env.DATABASE_URL
  WARN   service-boundary      LLM: "Direct Prisma query in route handler"
  INFO   prefer-named-export   line 1: default export

  1 block, 1 warn, 1 info
```

Runs all three check types. Useful for:
- Manual verification during development
- CI integration: `agent-harness check src/` as a pipeline step
- Validating rules after editing enforcement.yaml

**`agent-harness status [--last <period>]`**
Aggregate enforcement metrics from traces.

```
$ agent-harness status --last 7d

Rules active: 8 (2 block, 4 warn, 2 info)

Last 7 days across 12 agent sessions:
  Rule                    Fired   Blocked   Self-corrected   Override
  no-env-access             3        3          -               0
  no-console-log           14        -         12               2
  service-boundary          7        -          5               2
  component-srp             2        -          1               1

  CI first-push pass rate:  78% (was 61% before enforcement)
  Avg review rounds:        1.4 (was 2.3)
```

**`agent-harness trace`**
Passthrough to existing `agent-trace` CLI. Convenience alias.

### Implementation

Bash script, consistent with the rest of the project. Sources `enforce-lib.sh` for rule-running logic. Sources `ci-gate`'s detection functions for `init`.

## Component 3: Interactive Dispatch Mode

### Skill Definition

Location: `skills/dispatch/`

```markdown
---
name: dispatch
description: Work on a Linear issue or free-form task with full harness enforcement
arguments:
  - name: target
    description: Linear issue ID (ENG-123) or free-form task description
---
```

### Session Configuration

The dispatch skill runs inside the user's existing Claude Code session. To activate enforcement hooks, the skill:

1. Exports agent env vars (`CLAUDE_AGENT_MODE=1`, `CLAUDE_AGENT_ISSUE_ID`, `CLAUDE_AGENT_BRANCH`, `CLAUDE_AGENT_WORKTREE`) into the session
2. Hooks read these env vars and activate accordingly (same gate pattern as autonomous mode)
3. For parallel sub-agent work, dispatch spawns child Claude processes in worktrees (same as autonomous mode) — these get their own sessions with hooks active

The key difference from autonomous mode: the user's session is the orchestrator, not a bash script. The user can steer, answer questions, and approve decisions interactively while hooks enforce rules automatically.

### Flow

**If target is a Linear issue ID:**
1. `linear issue view <ID>` — fetch title, description, acceptance criteria
2. Check for sub-issues: `linear issue list --parent <ID>`
3. If sub-issues exist → smart routing (see below)
4. If no sub-issues → single-issue flow

**If target is free-form text:**
1. `linear issue create --team <configured-default> --title "..." --label Agent`
2. Capture the new issue ID
3. Single-issue flow

**Single-issue flow:**
1. Create worktree: `git worktree add ~/.claude/worktrees/<repo>/issue-<ID> -b agent/<ID>`
2. Check for `.claude/enforcement.yaml` — if missing, suggest `agent-harness init`
3. Update Linear: `linear issue update <ID> --status "In Progress"`
4. Work on the issue following the normal implementation workflow
5. Hooks enforce rules automatically during the session
6. Run `ci-gate` before pushing
7. Push branch, create PR: `gh pr create` or `linear issue pr`
8. Post implementation report: `linear comment add <ID> "..."`
9. Update status: `linear issue update <ID> --status "In Review"`

**Nested issue flow (smart routing — option C):**

When the dispatched issue has sub-issues, analyze the dependency graph and present options:

```
ENG-100 has 3 sub-issues:
  ENG-101: Dashboard API endpoints (no deps)
  ENG-102: Dashboard UI components (depends on ENG-101)
  ENG-103: Dashboard data migration (no deps)

ENG-101 and ENG-103 can run in parallel.
ENG-102 needs ENG-101 to finish first.

Options:
  1. Parallel: spawn agents for 101+103, then 102
  2. Sequential: work through each in this session
  3. Pick one to start with
```

For parallel execution, spawn sub-agents with scope enforcement. For sequential, work through in dependency order within the session. Either way, run parent-level integration checks after all children complete.

### Shared Library Extraction

Extract reusable functions from `bin/claude-agent-runner` into sourced libraries:

```
lib/
  agent-core.sh        # worktree setup/teardown, env config, identity exports
  agent-linear.sh      # Linear API functions (wraps linear-cli, falls back to curl)
  agent-github.sh      # PR creation, review posting
  agent-ci.sh          # ci-gate wrapper, retry-with-fix logic
```

Both `bin/claude-agent-runner` (autonomous) and `skills/dispatch/` (interactive) source these libraries. The runner's main loop and polling logic stay in the runner script; the dispatch skill drives the same functions conversationally.

**Migration strategy:** Defer full lib/ extraction to a separate effort. For the first iteration, the dispatch skill duplicates the small number of functions it needs (worktree setup, Linear issue fetch, PR creation). This avoids coupling the new skill to a risky refactor of the 2,450-line runner. Consolidation into shared lib/ files happens as a follow-up once both the autonomous runner and dispatch skill are stable and the shared interface is clear from actual usage.

**When lib/ extraction happens:** Map functions to libraries based on actual usage patterns. Global variables in the runner will need to become function parameters or config reads. Test the extraction by running the full agent-runner test suite after each function is moved.

## Component 4: Linear CLI Integration

### Tool Selection

Use [schpet/linear-cli](https://github.com/schpet/linear-cli) directly.

- Deno compiled to native binary — lightweight, no runtime dependencies
- 406 commits, actively maintained
- Covers: issue CRUD, comments, status updates, team listing, PR integration
- Already has a Claude Code skill

### Installation

```bash
brew install schpet/tap/linear
```

Add to `setup.sh` as an optional dependency check.

### Usage Mapping

| Operation | Command |
|---|---|
| Fetch issue | `linear issue view <ID>` |
| Create issue | `linear issue create --team <T> --title "..." --label Agent` |
| Update status | `linear issue update <ID> --status "In Progress"` |
| Add comment | `linear comment add <ID> "..."` |
| List by label | `linear issue list --label Agent` |
| List children | `linear issue list --parent <ID>` |
| Create child | `linear issue create --parent <ID> --team <T> --title "..."` |

**Verification needed:** The `--parent`, `--label`, and `--status` flags above are target commands, not confirmed CLI features. Commands that `linear-cli` doesn't support yet fall back to the existing GraphQL wrapper. Verify each command against actual CLI help during implementation and document which ones need the fallback.

### Migration from Raw GraphQL

The agent-runner's `linear_*` functions currently use raw `curl` + GraphQL. Migrate incrementally:

```bash
# Wrapper pattern during migration
linear_get_issue() {
  linear issue view "$1" --json 2>/dev/null || \
    _linear_graphql_fallback "issue" "$1"    # existing curl implementation
}
```

Replace each function as the CLI covers the need. Keep the fallback for any operations the CLI doesn't support yet (e.g., complex filtered queries, webhook management).

### Token Savings

MCP schema injection loads the full Linear API tool definitions every turn — hundreds of tokens of schema regardless of whether Linear tools are used. The CLI approach: zero tokens when not called, and only the output of the specific command when called. For a typical agent session that interacts with Linear 5-10 times, this saves thousands of tokens of schema overhead.

## Component 5: Tracing & Validation

### New Event Category: `enforcement`

Extends the existing JSONL trace format with enforcement events:

```jsonl
{"ts":"2026-03-11T14:32:01Z","cat":"enforcement","event":"rule.checked","rule":"no-console-log","check":"grep","file":"src/routes/users.ts","result":"pass"}
{"ts":"2026-03-11T14:32:01Z","cat":"enforcement","event":"rule.fired","rule":"no-env-access","check":"grep","file":"src/routes/users.ts","level":"block","line":42,"detail":"process.env.DATABASE_URL"}
{"ts":"2026-03-11T14:32:05Z","cat":"enforcement","event":"rule.fired","rule":"service-boundary","check":"llm","file":"src/routes/users.ts","level":"warn","detail":"Direct Prisma call in route handler","model":"haiku","latency_ms":820}
{"ts":"2026-03-11T14:32:08Z","cat":"enforcement","event":"self_corrected","rule":"service-boundary","file":"src/routes/users.ts","detail":"Agent moved query to UserService"}
```

### Event Types

| Event | When | Fields |
|---|---|---|
| `rule.checked` | Any rule evaluated | rule, check, file, result (pass/fail) |
| `rule.fired` | Rule violation detected | rule, check, file, level, line (if applicable), detail |
| `rule.skipped` | LLM check timed out or errored | rule, file, reason |
| `self_corrected` | Agent fixed a warn violation | rule, file, detail |
| `override` | Human explicitly bypassed a rule | rule, file, reason |
| `rule.escalated` | Rule level auto-upgraded | rule, from, to, reason, auto (bool) |
| `rule.downgraded` | Check type converted (LLM→grep) | rule, from, to, new_pattern, proposed (bool) |
| `guidance.suggested` | CLAUDE.md guidance proposed | rule, target, fires, sessions |

### Self-Correction Detection

When a `warn`-level rule fires on a file, the enforcement hook writes a `{file, rule, timestamp}` entry to `/tmp/enforce-pending-<session_id>.json` (session ID from `$CLAUDE_SESSION_ID` or fallback to PID-based). On the next Edit/Write to the same file, the post-hook re-runs the matching rule. If it passes, emit a `self_corrected` event and remove the entry. Pending entries are cleaned up when the session ends (or after a 4-hour TTL as a safety net).

### Nested Ticket Tracing

Every enforcement event includes an `issue` field (the Linear issue ID). For orchestrated work, also includes `parent` for child issues. This enables aggregation:

```bash
agent-trace show ENG-100                    # parent + all children
agent-trace show ENG-100 --filter enforcement   # enforcement events only
agent-harness status --issue ENG-100        # rollup across hierarchy
```

### Metrics

`agent-harness status` computes from traces:

- **Rule fire rate:** how often each rule triggers (per session, per time period)
- **Block rate:** how often block-level rules prevent actions
- **Self-correction rate:** percentage of warn-level violations the agent fixes without human intervention
- **Override rate:** how often humans bypass rules (signal for rule refinement)
- **CI first-push pass rate:** percentage of agent sessions where ci-gate passes on first attempt (tracks improvement over time)
- **Time-to-merge:** from issue pickup to PR merge (tracks overall efficiency)

### Viewer Integration

Extend `agent-trace-viewer.html` to render enforcement events:
- Color-coded by level (red=block, yellow=warn, gray=info)
- Filter chip for enforcement category
- Self-correction shown as paired events (warn → fix)

## File Structure Changes

```
bin/
  agent-harness              # NEW — CLI for init, check, status
  claude-agent-runner        # MODIFIED — sources from lib/
  ci-gate                    # UNCHANGED
  agent-trace                # MODIFIED — enforcement filter support

lib/                         # NEW — extracted shared functions
  agent-core.sh              # worktree, env, identity
  agent-linear.sh            # Linear CLI wrapper + fallback
  agent-github.sh            # PR, review
  agent-ci.sh                # ci-gate wrapper

hooks/
  enforce-pre.sh             # NEW — PreToolUse:Edit,Write
  enforce-post.sh            # NEW — PostToolUse:Edit,Write
  enforce-lib.sh             # NEW — shared enforcement logic
  block-destructive.sh       # UNCHANGED (becomes built-in rule)
  stop-gate.sh               # UNCHANGED (becomes built-in rule)
  command-budget.sh          # UNCHANGED (becomes built-in rule)
  scope-guard.sh             # UNCHANGED (becomes built-in rule)
  # ... other existing hooks unchanged

skills/
  dispatch/                  # NEW — interactive mode skill

config/
  config.example.json        # MODIFIED — add enforcement defaults
```

## Per-Project Config Files

```
<project-root>/
  .claude/
    enforcement.yaml         # enforcement rules
    patterns/                # markdown docs explaining each rule's rationale
      no-env-access.md
      service-boundary.md
      ...
    orchestrator/
      <ISSUE-ID>/
        enforcement.yaml     # integration-phase rules for orchestrated issues
```

## Dependencies

- **yq** — YAML parsing in bash (single binary, `brew install yq`)
- **linear-cli** — Linear API access (`brew install schpet/tap/linear`)
- **biome** (optional) — AST-level enforcement, only if project uses it
- **Anthropic API key** — for LLM-judged rules (Haiku). Set via env var referenced in config.

## Implementation Order

1. **enforce-lib.sh + enforce-pre.sh + enforce-post.sh** — the core enforcement hooks with grep check support only. Get the hook mechanics, YAML parsing, and block/warn/info routing working.
2. **enforcement.yaml schema** — define and validate the config format.
3. **Biome check type** — add AST-level checking to the enforcement hooks.
4. **LLM check type** — add Haiku-judged rules with timeout handling.
5. **agent-harness check** — manual rule-running CLI.
6. **Tracing integration** — emit enforcement.* events to JSONL traces.
7. **agent-harness init** — project bootstrapper.
8. **agent-harness status** — metrics aggregation from traces.
9. **skills/dispatch/** — interactive mode skill (duplicates needed functions initially).
10. **Linear CLI migration** — swap GraphQL calls for linear-cli incrementally.
11. **lib/ extraction** — consolidate shared functions once dispatch and runner interfaces stabilize.
12. **Self-correction detection** — track warn → fix patterns.
13. **Auto-escalation (v1)** — threshold-based warn→block promotion from self-correction data.
14. **Viewer updates** — enforcement events in trace viewer.
15. **Check-type downgrade (v2)** — Haiku meta-analysis to convert LLM rules to grep/biome.
16. **CLAUDE.md guidance injection (v2/v3)** — cross-session aggregation to suggest preventive guidance.

## Open Questions

1. **Biome plugin authoring:** For projects that need custom AST rules beyond biome's built-in set, how much do we invest in authoring tooling? First iteration: only use rules biome already ships. Defer custom plugins.
2. **Rule dependencies:** Can one rule reference another? (e.g., "if no-raw-sql fires, also check for missing service layer") First iteration: no. Rules are independent.
3. **Multi-language support:** enforcement.yaml rules with biome only work for JS/TS. Ruff for Python, clippy for Rust. Do we abstract the linter interface? First iteration: biome only. Add others as needed.

## Resolved Decisions

- **LLM rule caching:** Yes — cache by file content hash, skip re-check if unchanged. Specified in check types section.
- **YAML parsing:** Use `yq -o json` conversion + `jq` queries, not shell variable caching.
- **Config versioning:** `version: 1` is the only supported version. Unknown fields are ignored. Version bumps addressed when needed.
- **Log file location:** `~/.config/claude-agents/logs/enforcement.log` (outside project tree).
- **Baseline metrics:** v1 shows current rates only. "Before/after" comparisons deferred until baseline snapshot mechanism is designed.
- **lib/ extraction:** Deferred. Dispatch duplicates needed functions initially; consolidation follows once shared interface is clear.

## Roadmap: Workflow Enforcement + Skill Migration

### Phase 1: Keep superpowers for interactive sessions only

Superpowers plugin is useful for developer-in-the-loop brainstorming and plan writing. Do NOT load it into agent-runner sessions — autonomous agents don't need brainstorming, and the enforcement overhead (hundreds of tokens of meta-skill context per session) is wasteful. The runner's hooks provide deterministic enforcement that's cheaper and more reliable.

### Phase 2: Port useful skill content

Port the 2-3 genuinely valuable superpowers skill *contents* into the project's own `skills/` directory:
- Brainstorming flow (the structured design process, not the enforcement wrapper)
- Plan review prompts (the reviewer prompt templates, not the loop machinery)
- Keep existing project skills as-is (implement, orchestrate, scoped-worker, etc.)

### Phase 3: Workflow enforcement in enforcement.yaml

Add a `workflows` section to enforcement.yaml that deterministically enforces skill usage via hooks:

```yaml
workflows:
  - name: tdd-required
    skill: implement
    trigger: session-start       # auto-inject on issue work
    mode: auto-invoke
    evidence: "tests/**/*.test.ts"

  - name: report-before-done
    skill: agent-report
    trigger: pre-completion
    mode: block                  # block completion without artifact
    evidence: ".claude/agent-reports/*.md"

  - name: fix-ci-failures
    skill: ci-fix
    trigger: ci-failed
    mode: auto-invoke
```

Three enforcement modes:
- **`auto-invoke`** — Hook injects skill content into agent context automatically (zero-token when not triggered)
- **`block`** — Block completion without evidence artifact
- **`warn`** — Inject context suggesting the skill

This replaces `using-superpowers` entirely. Instead of LLM-mediated "did you remember to check for skills?", hooks deterministically inject the right workflow. Cheaper, more reliable, project-configurable.

### Phase 4: Drop superpowers dependency

Once workflow enforcement is proven, superpowers becomes redundant. All useful content lives in project skills, all enforcement is deterministic via hooks. The plugin can be removed.

## References

- [Agent Backpressure](https://latentpatterns.com/glossary/agent-backpressure) — automated feedback mechanisms for agent self-correction
- [Levels of Agentic Engineering](https://www.bassimeledath.com/blog/levels-of-agentic-engineering) — framework for AI-assisted coding maturity (levels 5-7 relevant)
- [Dispatch](https://github.com/bassimeledath/dispatch) — Claude Code skill for multi-agent coordination (comparable system)
- [schpet/linear-cli](https://github.com/schpet/linear-cli) — Linear CLI tool for token-efficient API access
