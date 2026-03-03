---
name: implement
description: Full implementation workflow for a task or Linear issue. Plans, writes tests first, implements, runs CI gate, and creates an agent report. Use when starting any non-trivial feature, bug fix, or refactor.
user_invocable: true
---

# implement

Full TDD implementation workflow. Follow every step in order — do not skip phases.

## Phase 1: Understand

1. Read `CLAUDE.md` in the project root for all conventions, architecture, and coding standards
2. Read the task description carefully. If this is a Linear issue, parse the identifier, title, and description
3. Explore the relevant parts of the codebase — understand existing patterns before writing anything
4. If requirements are unclear or you need human input, use the `blocked` skill instead of guessing

## Phase 2: Plan

1. Identify all files that need to change
2. Draft an implementation approach covering:
   - Data model / schema changes (if any)
   - API contracts (if any)
   - Component structure (if UI)
   - Edge cases and error handling
3. If the change touches more than 3 files or involves architectural decisions, write a brief plan to `.claude/plans/` before proceeding

## Phase 3: Tests First (MANDATORY)

1. Write failing tests based on the plan — use the project's test framework and patterns
2. Cover: happy path, edge cases, error conditions
3. Run the tests and **verify they fail** — this confirms you're testing the right thing
4. If tests pass before implementation, your tests aren't testing the new behavior

## Phase 4: Implement

1. Write the minimum code needed to make tests pass
2. Follow the project's conventions from `CLAUDE.md` — don't introduce new patterns
3. Run linter and type checker (whatever the project uses) — fix all issues before proceeding
4. Commit with conventional commit messages as you go (e.g., `feat:`, `fix:`, `test:`)

## Phase 5: Validate (DO NOT SKIP)

1. Run the full test suite — not just your new tests
2. Run the CI gate if available: `ci-gate .`
3. If any UI changed, take screenshots and verify visually
4. Create an agent report using the `agent-report` skill

## Important Rules

- **Do NOT push or open PRs** — the agent runner handles that externally
- **Do NOT modify files outside the current worktree**
- If you get stuck or need clarification, use the `blocked` skill
- If CI fails, use the `ci-fix` skill
- Commit documentation updates (CHANGELOG, CLAUDE.md, architecture docs) as part of your work
- Match existing project patterns — don't introduce new frameworks, libraries, or conventions
