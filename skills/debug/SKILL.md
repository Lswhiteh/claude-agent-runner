---
name: debug
description: Systematic debugging workflow. Reproduces the issue, isolates the root cause, fixes it, and adds a regression test. Use when something is broken and the cause isn't obvious.
user_invocable: true
---

# debug

Systematic approach to finding and fixing bugs. Do not guess — follow the evidence.

## Step 1: Reproduce

Before anything else, reproduce the bug reliably:

- What's the exact error message or incorrect behavior?
- What are the steps to trigger it?
- Does it happen every time or intermittently?
- When did it start? (check recent commits: `git log --oneline -20`)

If you can't reproduce it, you can't verify the fix. Get a reliable repro first.

## Step 2: Gather Evidence

Read error messages carefully — they usually point to the exact problem:

```bash
# Check logs
tail -100 <log-file>

# Check recent changes that might have caused it
git log --oneline --since="2 days ago"
git diff HEAD~5 -- <suspect-file>

# Check if the test suite catches it
npx vitest run <related-test-file>
```

## Step 3: Form a Hypothesis

Based on the evidence, form ONE specific hypothesis:
- "The null check on line 42 doesn't account for empty strings"
- "The migration added a NOT NULL column without a default"
- "The API response shape changed but the client type wasn't updated"

## Step 4: Narrow Down

Bisect to isolate the root cause:

### For runtime errors:
- Add targeted logging around the suspect code
- Check the exact values at the point of failure
- Trace the data backwards — where did the bad value come from?

### For regressions:
```bash
# Find the commit that introduced the bug
git bisect start
git bisect bad          # current commit is broken
git bisect good <hash>  # this commit was working
# Test each bisect step, mark good/bad
```

### For intermittent bugs:
- Race conditions: add logging with timestamps
- State-dependent: check what state differs between success and failure
- Environment-dependent: compare env vars, node version, OS

## Step 5: Write a Failing Test

BEFORE fixing the bug, write a test that reproduces it:

```bash
# This test should FAIL right now
npx vitest run <test-file> -t "should handle <the-bug-scenario>"
```

This ensures:
1. You understand the bug correctly
2. Your fix actually works
3. The bug can't regress silently

## Step 6: Fix

Apply the minimal fix. Don't refactor surrounding code — that's a separate task.

## Step 7: Verify

1. Run the failing test — it should pass now
2. Run the full test suite — nothing else should break
3. Manually verify the original repro steps work correctly
4. Check edge cases related to your fix

## Rules

- Don't fix symptoms — find the root cause
- Don't add workarounds unless the real fix requires a larger change (and document the workaround with a TODO)
- One bug, one fix, one commit — don't bundle unrelated changes
- If the fix is in a different area than expected, investigate why your initial assumption was wrong
- If you can't find the root cause after 30 minutes of investigation, step back and re-read the error message from scratch
