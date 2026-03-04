---
name: spec-writer
description: Transforms a high-level feature idea into structured development requirements. Produces a requirements document with sized work units suitable for the pipeline command. Can be used interactively for clarification.
user_invocable: true
---

# spec-writer

Turn a high-level idea or feature description into structured development requirements.

## Phase 1: Understand the Idea

1. Read the input idea document carefully
2. If working in a project directory, read `CLAUDE.md` for context on the codebase
3. Identify:
   - The core user problem being solved
   - Key functionality required
   - Implicit requirements (auth, validation, error handling, etc.)
   - Technical constraints from the existing codebase

## Phase 2: Ask Clarifying Questions (if interactive)

If requirements are ambiguous, ask focused questions about:
- User-facing behavior (what should the user see/experience?)
- Edge cases (what happens when X fails?)
- Scope boundaries (what is NOT included?)
- Technical preferences (which approach for X?)

Keep questions concrete and actionable — not open-ended.

## Phase 3: Decompose into Work Units

Break the requirements into implementation stories:

- Each story should be **completable in one agent session** (1-3 hours, 100-300 turns)
- Stories should be **independently implementable** where possible
- Specify **dependencies** between stories when ordering matters
- Each story needs **clear acceptance criteria**

### Story sizing guidance

| Size | Estimate | Example |
|------|----------|---------|
| Trivial | 1 | Add a config flag, rename a field |
| Small | 2 | Single API endpoint with tests |
| Medium | 3 | Feature with API + frontend + tests |
| Large | 5 | Multi-component feature, schema changes |
| Very Large | 8 | Cross-cutting concern, major refactor |

Stories estimated at 8+ should be broken down further.

### Orchestration markers

For stories that involve multiple layers (backend + frontend + data), note in the description that they should get the "Orchestrate" label. The orchestrator will decompose them further at implementation time.

For single-layer stories, leave them unmarked — they'll run as single-agent tasks.

## Phase 4: Output Structured Requirements

Output a markdown document with this structure:

```markdown
# Feature: <title>

## Overview
<1-2 paragraph summary of the feature>

## Stories

### 1. <Story title>
**Estimate:** <points>
**Labels:** <feature|bug|chore|improvement>
**Dependencies:** <none or list of story numbers>

<Description with acceptance criteria>

### 2. <Story title>
...
```

This format is compatible with the `--pipeline` command for direct Linear issue creation.

## Important Rules

- **Be specific** — vague acceptance criteria lead to vague implementations
- **Include error cases** — what happens when things go wrong?
- **Don't over-decompose** — 3-8 stories is usually right for a feature
- **Mark dependencies explicitly** — the pipeline respects `--sequenced` ordering
- **Include test expectations** — what should tests verify?
