---
name: scoped-worker
description: Scope-aware implementation workflow for orchestrated subtasks. Wraps the implement skill with file scope enforcement and scope-overflow handling. Used by workers spawned from the orchestrator — not invoked directly.
user_invocable: false
---

# scoped-worker

Implementation workflow for a scoped subtask within an orchestrated feature. You are one of several workers — stay within your scope.

## Phase 1: Understand Your Scope

1. Read `CLAUDE.md` for project conventions
2. Read your subtask spec from the issue description — pay attention to:
   - **File Scope**: Files you CAN write to
   - **Off Limits**: Files you MUST NOT touch
   - **Shared Files**: Files modified by earlier subtasks (read-only for you)
   - **Acceptance Criteria**: What "done" means for your subtask
   - **Context**: How your work connects to other subtasks
3. If shared file diffs are provided, read them to understand what changed before you

## Phase 2: Plan

1. Identify all files within your scope that need changes
2. Draft your approach — stay within scope boundaries
3. If you realize you need to modify an out-of-scope file:
   - **Do NOT modify it** — the scope-guard hook will block you
   - Instead, document the needed change (see Phase 5: Scope Overflow)
   - Continue with what you CAN do within scope

## Phase 3: Tests First (MANDATORY)

1. Write failing tests — test files must be within your scope
2. Verify tests fail
3. Cover acceptance criteria from your subtask spec

## Phase 4: Implement

1. Write minimum code to pass tests — only touch files in your scope
2. Follow project conventions from `CLAUDE.md`
3. Run linter and type checker — fix issues in your scoped files only
4. Commit with conventional commit messages as you go
5. If type errors come from out-of-scope files, document them as scope overflow

## Phase 5: Scope Overflow (if needed)

If you need changes outside your scope to complete your work:

1. Create `.claude/orchestrator/scope-overflow-<YOUR_SUBTASK_ID>.md` with:

```markdown
# Scope Overflow: <subtask title>

## Required Changes

### <file path>
**Why**: <why this change is needed>
**What**: <description of the change needed>
```

2. Commit the overflow file
3. Continue implementing everything you CAN within scope — don't block on overflow items

The orchestrator will create a follow-up subtask to handle overflow changes.

## Phase 6: Validate

1. Run tests within your scope
2. If CI gate is available, run it (some failures may be expected if depending on other subtasks)
3. Create your agent report at `.claude/agent-reports/<IDENTIFIER>.md`

## Important Rules

- **Scope is hard-enforced** — the scope-guard hook will deny writes outside your scope
- **Reads are unrestricted** — you can read any file for context
- **Do NOT push or open PRs** — the orchestrator handles that
- **Do NOT modify shared files** unless they are in your scope — document needed changes as scope overflow
- **Commit frequently** — atomic commits within your scope
- **Do NOT try to work around the scope guard** — if you need something out of scope, use the overflow mechanism
