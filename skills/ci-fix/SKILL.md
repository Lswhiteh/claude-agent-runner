---
name: ci-fix
description: Diagnose and fix CI gate failures. Parses error output from type-checking, tests, linting, or build steps and applies targeted fixes. Use when CI gate fails after implementation.
user_invocable: true
---

# ci-fix

Fix CI gate failures systematically. Do not shotgun fixes — diagnose first, then apply targeted changes.

## Step 1: Get the Full Error Output

Run the CI gate and capture output:

```bash
ci-gate .
```

If output is truncated (RTK filtering), get the raw version:

```bash
rtk proxy ci-gate .
```

Or run individual checks to isolate which step fails. Check the project's `CLAUDE.md`, `package.json`, `Makefile`, or `.ci-gate` file for the specific commands.

## Step 2: Categorize Errors

Group errors into categories:

- **Type errors**: Missing types, incorrect generics, interface mismatches
- **Test failures**: Assertion errors, missing mocks, timing issues
- **Lint errors**: Unused imports, formatting, rule violations
- **Build errors**: Missing modules, import resolution, config issues

## Step 3: Fix in Order

Fix in this order (earlier fixes often resolve later errors):

1. **Import/module resolution** — missing exports, wrong paths
2. **Type errors** — add types, fix generics, update interfaces
3. **Lint errors** — auto-fix what you can (check project's lint fix command)
4. **Test failures** — update assertions, fix mocks, adjust test setup
5. **Build errors** — usually resolved by fixing the above

## Step 4: Verify

After each category of fix, re-run the specific failing check to confirm. Then run the full CI gate:

```bash
ci-gate .
```

## Step 5: Commit

```bash
git add -A
git commit -m "fix: resolve CI failures for <IDENTIFIER>"
```

## Rules

- Fix ALL errors, not just the first one
- Do NOT disable lint rules, skip tests, or suppress type errors unless there's genuinely no other option
- Do NOT modify test assertions to make them pass if the implementation is wrong — fix the implementation
- If a test is genuinely wrong (testing old behavior that was intentionally changed), update the test with a comment explaining why
- If you cannot fix an error after multiple attempts, document it in the agent report
