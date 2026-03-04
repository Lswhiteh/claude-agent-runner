---
name: preflight
description: Quick issue triage before full implementation. Classifies the issue type, checks if requirements are sufficient, identifies risks and unknowns, and produces a structured assessment. Used by the agent runner to catch problems early before burning 500 turns.
user_invocable: true
---

# preflight — Issue Triage & Pre-flight Check

Fast assessment of an issue before committing to full implementation. This prevents wasting agent turns on under-specified issues, flags risks early, and selects the right workflow.

## Input

You'll receive an issue identifier, title, and description. You also have access to the codebase.

## Step 1: Classify the Issue

Determine the issue type based on the description:

| Type | Signals | Workflow |
|------|---------|----------|
| `bug` | "broken", "error", "regression", "not working", stack traces, error messages | Use `rca` skill → `debug` skill |
| `feature` | "add", "implement", "create", "new", "support" | Use `implement` skill |
| `refactor` | "refactor", "improve", "clean up", "migrate", "rename" | Use `implement` skill (no new behavior, tests should still pass) |
| `chore` | "update", "upgrade", "configure", "setup" | Minimal — just do it |
| `unclear` | Vague description, no acceptance criteria, ambiguous scope | Use `blocked` skill |

## Step 2: Check Requirements Sufficiency

For each type, verify minimum requirements are present:

### For bugs:
- [ ] Specific error message or wrong behavior described?
- [ ] Steps to reproduce included (or inferable from context)?
- [ ] Expected vs actual behavior clear?
- [ ] Affected area/feature identifiable?

### For features:
- [ ] Acceptance criteria defined (or clearly inferable)?
- [ ] Scope bounded? (not "improve the app")
- [ ] Enough detail to write tests BEFORE implementation?
- [ ] No open business/product decisions embedded?

### For refactors:
- [ ] Clear what needs to change and why?
- [ ] Success criteria defined? (same behavior, better structure)
- [ ] Scope bounded to specific files/modules?

**If any critical requirement is missing**, output `BLOCK` with specific questions.

## Step 3: Assess Complexity & Risk

Quick codebase scan to estimate scope:

```bash
# Find files likely affected
grep -rn "<key terms from issue>" --include="*.ts" --include="*.tsx" -l

# Check test coverage of affected area
find . -name "*.test.*" -path "*<affected-area>*"

# Check for recent changes in affected area
git log --oneline -10 -- <affected-files>
```

Rate complexity:
- **Low**: 1-3 files, well-tested area, clear pattern to follow
- **Medium**: 4-10 files, some test coverage, may need new patterns
- **High**: 10+ files, cross-cutting concern, schema changes, or architectural decision

Rate risk:
- **Low**: Additive change, well-tested, isolated
- **Medium**: Modifies existing behavior, moderate test coverage
- **High**: Schema migration, auth changes, data loss potential, affects payments

## Step 4: Output Assessment

Output ONLY a JSON object:

```json
{
  "type": "bug" | "feature" | "refactor" | "chore" | "unclear",
  "verdict": "proceed" | "block",
  "complexity": "low" | "medium" | "high",
  "risk": "low" | "medium" | "high",
  "skills": ["rca", "debug"],
  "affected_files": ["src/foo.ts", "src/bar.ts"],
  "has_tests": true,
  "notes": "Brief assessment of what needs to happen",
  "block_reason": "Only if verdict is block — specific missing requirements",
  "block_questions": ["Question 1?", "Question 2?"]
}
```

## Rules

- Spend no more than 5 minutes on this assessment
- Do NOT start implementing — this is analysis only
- Be honest about missing requirements — it's cheaper to block now than after 400 turns
- If the issue is a bug, always recommend `rca` as the first skill
- If complexity is high, note that in the assessment — the runner may want to break it down
