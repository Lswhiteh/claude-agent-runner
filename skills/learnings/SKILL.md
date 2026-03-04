---
name: learnings
description: Record discoveries, gotchas, and hard-won knowledge for future agent runs. Accumulates a per-repo knowledge base that persists across issues. Use whenever you discover something non-obvious about the codebase, dependencies, or environment.
user_invocable: true
---

# learnings — Cross-Run Knowledge Base

Record things you learned during this run so future agent sessions benefit. This builds a persistent knowledge base that reduces repeated mistakes and speeds up future implementations.

## When to Record a Learning

Record a learning when you discover:

- **Codebase gotchas**: "The `users` table has a soft-delete column — always filter by `deleted_at IS NULL`"
- **Environment quirks**: "The test database needs `pgcrypto` extension enabled before running migrations"
- **Dependency issues**: "The `date-fns` library doesn't handle timezone-aware dates — use `luxon` for timezone work"
- **Test patterns**: "Integration tests require `NEXT_PUBLIC_API_URL` to be set or they silently skip"
- **CI/build issues**: "The build fails if you import from `@/server` in a client component — use dynamic import"
- **Performance pitfalls**: "The `getUsers` query N+1s on roles — always include `.with('roles')` in the query"
- **Root causes of past bugs**: "The auth middleware doesn't run on API routes under `/api/public/` — this is by design"
- **Architectural decisions**: "The team chose Zustand over Redux for state management — see ADR-003"
- **Review feedback patterns**: "Reviewers consistently flag missing input validation on API endpoints"

## How to Record

1. Read the existing learnings file (if it exists):

```bash
cat .claude/learnings.md 2>/dev/null || echo "No existing learnings"
```

2. Append your new learning to `.claude/learnings.md`:

```markdown
## [YYYY-MM-DD] <IDENTIFIER>: <Short title>

**Category**: codebase | environment | dependency | testing | ci | performance | architecture | review-pattern

**Learning**: <1-3 sentences describing what you discovered>

**Context**: <How you discovered it — what went wrong or what you tried>

**Impact**: <What would go wrong if a future agent doesn't know this>
```

3. Commit:

```bash
git add .claude/learnings.md
git commit -m "docs: add learning from <IDENTIFIER> — <short description>"
```

## How to Use Existing Learnings

At the START of every implementation:

```bash
if [ -f .claude/learnings.md ]; then
  cat .claude/learnings.md
fi
```

Read the learnings file and apply relevant knowledge to your current task. This prevents repeating mistakes and surfaces non-obvious constraints.

## Categories

| Category | Examples |
|----------|----------|
| `codebase` | Soft deletes, naming conventions, hidden dependencies between modules |
| `environment` | Required env vars, Docker setup quirks, OS-specific behavior |
| `dependency` | Library limitations, version constraints, undocumented behavior |
| `testing` | Test setup requirements, flaky test patterns, mock configurations |
| `ci` | Build system quirks, CI-specific environment differences |
| `performance` | N+1 queries, missing indexes, expensive operations |
| `architecture` | Design decisions, module boundaries, data flow constraints |
| `review-pattern` | Recurring reviewer feedback, team coding standards not in CLAUDE.md |

## Rules

- Keep learnings concise — future agents will read ALL of them at the start of every run
- Only record non-obvious things — don't record "you need to run npm install"
- Include the issue identifier so learnings can be traced back to their source
- Don't duplicate information already in CLAUDE.md — if it belongs there, put it there instead
- Periodically prune stale learnings (e.g., after a major refactor invalidates them)
- This file lives in the repo (committed), not in the agent's config — it's project-specific knowledge
