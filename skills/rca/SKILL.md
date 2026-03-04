---
name: rca
description: Root Cause Analysis for bug fixes. Forces evidence-based diagnosis before any code changes. Produces a structured RCA document proving you understand WHY the bug exists, not just WHERE it manifests. Use for any bug fix or regression.
user_invocable: true
---

# rca — Root Cause Analysis

You MUST complete this workflow before writing any fix for a bug. Fixing symptoms without understanding the root cause leads to regressions and whack-a-mole debugging.

## Phase 1: Reproduce (DO NOT SKIP)

Before anything else, create a **reliable reproduction**:

1. Write a failing test that demonstrates the bug:

```bash
# This test MUST fail before your fix and pass after
npx vitest run <test-file> -t "should <describe expected behavior>"
```

2. If you can't write a test (e.g., infrastructure issue), document the exact reproduction steps:
   - Commands to run
   - Expected vs actual output
   - Environment conditions required

3. If you **cannot reproduce** the bug:
   - Check if it's environment-dependent (versions, OS, config)
   - Check if it's state-dependent (specific data, timing, order of operations)
   - Check if it's already fixed on main (stale report)
   - If still can't reproduce after 15 minutes, use the `blocked` skill with what you've tried

**Gate**: Do NOT proceed to Phase 2 until you have a reliable reproduction.

## Phase 2: Isolate the Root Cause

Work backwards from the symptom to the origin. Document your investigation:

### 2a. Trace the failure chain

Start at the error/symptom and trace backwards:

```
SYMPTOM: [What the user sees]
  ← IMMEDIATE CAUSE: [What code produced the wrong result]
    ← UNDERLYING CAUSE: [Why that code behaved incorrectly]
      ← ROOT CAUSE: [The fundamental flaw — this is what you fix]
```

### 2b. Differentiate symptom from root cause

Ask yourself:
- **Is this WHERE the bug manifests, or WHY it exists?** (Fix the WHY)
- **Would fixing this ONE thing prevent all manifestations?** (If not, dig deeper)
- **Could this same root cause cause OTHER bugs?** (If yes, you've likely found it)

Common root cause categories:
- **Wrong assumption**: Code assumes X but reality is Y (e.g., assumes non-null, assumes sorted)
- **Missing validation**: Bad data enters the system unchecked at a boundary
- **State corruption**: Something mutates shared state unexpectedly
- **Race condition**: Timing-dependent behavior with no synchronization
- **Contract violation**: Caller and callee disagree on interface semantics
- **Stale reference**: Code references something that changed (renamed, moved, deleted)

### 2c. Gather evidence

Before forming your hypothesis, collect concrete evidence:

```bash
# When did it start? Find the introducing commit
git log --oneline --since="1 week ago" -- <suspect-files>
git bisect start && git bisect bad && git bisect good <known-good>

# What changed around the affected code?
git log -p --follow -- <file>

# What does the actual data look like at the failure point?
# Add targeted logging, NOT printf-debugging everywhere
```

## Phase 3: Document the RCA

Before writing ANY fix, create `.claude/rca/<IDENTIFIER>.md`:

```markdown
# RCA: <IDENTIFIER>

## Bug Summary
[1-2 sentences: what's broken and who it affects]

## Reproduction
[Test name or exact steps to reproduce]
[Include the failing test file and test name]

## Failure Chain
```
SYMPTOM: [observable problem]
  ← IMMEDIATE CAUSE: [code-level cause]
    ← ROOT CAUSE: [fundamental flaw]
```

## Root Cause
[Detailed explanation of WHY the bug exists, not just where]

## Evidence
- [Specific commit, log line, data point, or test output that proves this is the root cause]
- [Why alternative hypotheses were ruled out]

## Fix Strategy
[How the fix addresses the root cause, not the symptom]
[Why this fix won't introduce new bugs]

## Blast Radius
- [Other code that depends on the thing being fixed]
- [Whether the fix changes any interfaces or contracts]
- [Migration/data cleanup needed]
```

Commit the RCA document:

```bash
mkdir -p .claude/rca
git add .claude/rca/<IDENTIFIER>.md
git commit -m "docs: root cause analysis for <IDENTIFIER>"
```

## Phase 4: Fix with Precision

Now — and ONLY now — write the fix:

1. **Minimal fix**: Change the minimum code to address the root cause
2. **Regression test**: Your reproduction test from Phase 1 should now pass
3. **Blast radius tests**: Add tests for any code affected by the fix (from your blast radius analysis)
4. **No drive-by refactors**: Don't "improve" surrounding code in the same fix

```bash
# Verify: reproduction test now passes
npx vitest run <test-file> -t "should <expected behavior>"

# Verify: nothing else broke
npx vitest run

# Commit the fix separately from the RCA doc
git add <changed-files>
git commit -m "fix: <IDENTIFIER> — <concise root cause description>"
```

## Phase 5: Validate the Fix is Complete

- [ ] Reproduction test passes
- [ ] No other tests regressed
- [ ] RCA document is committed
- [ ] Fix addresses the ROOT cause, not a symptom
- [ ] Blast radius code is tested
- [ ] If the root cause could affect other areas, checked those too

## Anti-Patterns (DO NOT DO THESE)

- **Symptom patching**: Adding a null check where the real problem is data not being loaded
- **Shotgun fixing**: Changing 5 things and hoping one of them works
- **Copy-paste from StackOverflow**: Without understanding WHY the solution works
- **Suppressing the error**: Catching/swallowing the exception instead of fixing the cause
- **"Just restart it"**: Adding retry logic around a deterministic bug
- **Fixing the test**: Making the test match wrong behavior instead of fixing the code

## Rules

- The RCA document is MANDATORY for every bug fix — it proves you understand the problem
- If you can't explain the root cause in plain English, you don't understand it yet
- If your "fix" is more than 20 lines, question whether you're fixing the right thing
- Never commit a fix without a regression test
- If you discover the bug is actually a feature request or design issue, use `blocked` to clarify
