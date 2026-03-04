---
name: verify
description: Post-implementation verification that changes actually address the issue requirements. Checks each acceptance criterion, validates the fix is complete (not partial), and catches gaps before CI/PR. Use after implementation, before CI gate.
user_invocable: true
---

# verify — Post-Implementation Verification

CI passing does NOT mean the issue is resolved. This skill validates that your changes actually address what was asked for — not just that they compile and pass existing tests.

## Input

You need:
1. The original issue (identifier, title, description)
2. Your implementation (the diff from origin/main)

## Step 1: Extract Requirements

Parse the issue into a checklist of concrete requirements:

```markdown
## Requirements extracted from <IDENTIFIER>
- [ ] Requirement 1 (from: "user should be able to...")
- [ ] Requirement 2 (from: "when X happens, Y should...")
- [ ] Requirement 3 (inferred: error handling for the new feature)
```

For bug fixes, the requirements are:
- [ ] Root cause identified and documented (`.claude/rca/<ID>.md` exists)
- [ ] Reproduction test exists and was failing before the fix
- [ ] Fix addresses the root cause, not a symptom
- [ ] No regression in related functionality

## Step 2: Verify Each Requirement Against the Diff

For EACH requirement, find the specific code that satisfies it:

```bash
# Get all changes
git diff origin/main --stat
git diff origin/main -- <relevant-files>
```

For each requirement:
- **SATISFIED**: Point to the specific file:line that implements it
- **PARTIALLY SATISFIED**: Explain what's missing
- **NOT ADDRESSED**: Flag it — this is a gap

## Step 3: Check for Completeness Gaps

Common gaps that CI won't catch:

### Missing edge cases
- What happens with empty input?
- What happens with null/undefined?
- What happens at boundary values (0, MAX_INT, empty string)?
- What happens when the feature is used for the first time (no existing data)?

### Missing error handling
- What if the network call fails?
- What if the database query returns no results?
- What if the user doesn't have permission?
- Are error messages user-friendly?

### Missing integration points
- Did you update the API docs?
- Did you update the frontend to use the new API?
- Did you update the database schema AND the ORM types?
- Are there other callers of the function you changed?

### Missing tests
- Is there a test for EACH requirement?
- Are there tests for error paths, not just happy paths?
- For bug fixes: is there a regression test?

## Step 4: Self-Review the Diff

Read your own diff as if you're reviewing someone else's PR:

```bash
git diff origin/main
```

Check:
- [ ] No debug logging left in
- [ ] No TODO/FIXME without a ticket reference
- [ ] No commented-out code
- [ ] No hardcoded values that should be configurable
- [ ] No security issues (injections, exposed secrets, missing auth checks)
- [ ] No performance issues (N+1 queries, missing indexes, unbounded loops)

## Step 5: Output Verification Report

Write `.claude/verify/<IDENTIFIER>.md`:

```markdown
# Verification: <IDENTIFIER>

## Requirements Checklist
- [x] Requirement 1 — implemented in `src/foo.ts:42`
- [x] Requirement 2 — implemented in `src/bar.ts:15`
- [ ] Requirement 3 — NOT IMPLEMENTED (gap: error handling for X)

## Test Coverage
- [x] Happy path test: `tests/foo.test.ts:10`
- [x] Error path test: `tests/foo.test.ts:25`
- [ ] Edge case: empty input — NOT TESTED

## Self-Review Findings
- [Fixed] Removed debug console.log from src/foo.ts
- [OK] No security concerns identified

## Verdict
PASS | PARTIAL | FAIL

## Gaps (if PARTIAL or FAIL)
- [List specific gaps that need to be addressed]
```

Commit the verification report:

```bash
mkdir -p .claude/verify
git add .claude/verify/<IDENTIFIER>.md
git commit -m "docs: verification report for <IDENTIFIER>"
```

## Step 6: Fix Gaps

If verdict is PARTIAL or FAIL:
1. Fix each identified gap
2. Re-run verification
3. Update the report

Only proceed to CI when verdict is PASS.

## Rules

- This is NOT optional — run it after every implementation before CI
- Be brutally honest — gaps found here are MUCH cheaper than gaps found in review
- Don't count "it compiles" as verification — check actual behavior
- If you find a gap you can't fix (missing requirement info), use `blocked` skill
- The verification report is included in the agent report for reviewers to see
