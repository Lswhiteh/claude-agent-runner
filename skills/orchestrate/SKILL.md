---
name: orchestrate
description: Decomposes a multi-concern Linear issue into scoped subtasks. Explores the codebase, identifies work units, assigns file scopes, and outputs structured subtask JSON files. Used by the orchestrator supervisor — not invoked directly by agents.
user_invocable: false
---

# orchestrate

Decompose a parent ticket into scoped subtasks for parallel/sequential execution by worker agents.

## Phase 1: Understand the Codebase

1. Read `CLAUDE.md` for project conventions, architecture, and structure
2. Explore the codebase to understand:
   - Directory layout and module boundaries
   - Existing patterns (API routes, components, data models, test structure)
   - Shared infrastructure (types, config, utilities)
3. Read the parent issue description carefully — identify distinct concerns

## Phase 2: Identify Work Units

Break the issue into subtasks where each subtask:
- Has a **single concern** (e.g., "backend API", "frontend component", "database migration")
- Is sized for **100-200 turns** of agent work (roughly 1-3 hours)
- Has **clear acceptance criteria** that can be validated independently
- Has a **non-overlapping write scope** — no two subtasks write to the same files

### When NOT to decompose

If the issue is single-concern (touches one module, one layer), output:

```json
{"no_decomposition": true, "reason": "Single-concern issue — all changes in src/api/users.ts and its test"}
```

Write this to `.claude/orchestrator/no_decomposition.json` and stop.

### Decomposition rules

- **Max subtasks**: Read the limit from the orchestrator config (default 8)
- **Shared files** (types, config, package.json, migrations): Assign to the **first subtask** that needs them. Later subtasks get read-only access with diff context
- **No overlapping write scopes**: If two subtasks need the same file, either merge them or designate one as the owner
- **Dependency ordering**: If subtask B needs subtask A's output (e.g., types it defines), mark `depends_on`
- **Test files**: Each subtask owns its own test files — scope them alongside the implementation files

## Phase 3: Assign File Scopes

For each subtask, determine:

- **`scope`**: Files/directories the worker CAN write to (glob patterns ok)
- **`off_limits`**: Files/directories the worker MUST NOT touch
- **`shared_files`**: Files modified by earlier subtasks that this one needs to read

Be specific with scopes. Prefer file paths over broad directory globs:
- Good: `["src/api/preferences.ts", "src/api/__tests__/preferences.test.ts"]`
- Bad: `["src/"]`

## Phase 4: Write Subtask Files

For each subtask, write a JSON file to `.claude/orchestrator/subtask-NNN.json`:

```json
{
  "id": "001",
  "title": "Backend API for user preferences",
  "skill": "backend",
  "scope": ["src/api/preferences.ts", "src/api/__tests__/preferences.test.ts", "src/db/migrations/"],
  "off_limits": ["src/components/", "src/app/"],
  "shared_files": ["src/types/preferences.ts"],
  "depends_on": [],
  "acceptance_criteria": [
    "POST /api/preferences creates a preference record",
    "GET /api/preferences returns user's preferences",
    "Unit tests for both endpoints pass"
  ],
  "context": "This is part of a user preferences feature. The frontend (subtask 002) will consume these endpoints."
}
```

### Field reference

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Zero-padded sequence number (001, 002, ...) |
| `title` | Yes | Short imperative title for the sub-issue |
| `skill` | Yes | Which skill the worker should use: `backend`, `frontend`, `implement`, `data-flow`, etc. |
| `scope` | Yes | Files/dirs the worker can write to |
| `off_limits` | Yes | Files/dirs the worker must not touch (can be `[]` if scope is narrow enough) |
| `shared_files` | No | Files from earlier subtasks this one reads but doesn't own |
| `depends_on` | Yes | Array of subtask IDs this one must wait for (can be `[]`) |
| `acceptance_criteria` | Yes | Concrete, testable conditions for "done" |
| `context` | Yes | How this subtask fits into the larger feature — what other subtasks exist and how they connect |

## Important Rules

- **Do NOT create subtasks for documentation** — doc updates happen as part of each worker's regular flow
- **Do NOT create "integration test" subtasks** — integration validation is handled by the orchestrator after all subtasks complete
- **Do NOT scope to the entire repo** — every subtask must have a bounded file scope
- **Explore before decomposing** — don't guess at file paths. Read the codebase to find actual paths
- **Number subtasks in execution order** — 001 runs first, higher numbers run after their dependencies
