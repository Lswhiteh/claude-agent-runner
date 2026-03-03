---
name: simplify
description: Review changed code for quality, reuse, and efficiency. Identifies over-engineering, dead code, missing edge cases, and opportunities to simplify. Run after implementation and before final commit.
user_invocable: true
---

# simplify

Review your own changes with a critical eye. Look for ways to reduce complexity without losing functionality.

## What to Check

### 1. Over-engineering
- Abstractions that are only used once — inline them
- Config/options objects for things that will never change
- Generic solutions for specific problems
- Feature flags or backwards-compatibility shims that aren't needed

### 2. Dead Code
- Unused imports, variables, functions
- Commented-out code (delete it — git has history)
- Parameters that are always the same value
- Branches that can never execute

### 3. Duplication vs Premature Abstraction
- Three similar lines of code is better than a premature helper function
- But genuine duplication (same logic in 3+ places) should be extracted
- Use the "Rule of Three" — don't abstract until you see the pattern three times

### 4. Error Handling
- Don't catch errors you can't handle meaningfully
- Don't add validation for impossible states (trust internal code)
- Only validate at system boundaries (user input, external APIs)
- Remove try/catch blocks that just re-throw

### 5. Naming and Clarity
- Variable names should make comments unnecessary
- Function names should describe WHAT, not HOW
- Remove comments that restate the code
- Add comments only where the WHY isn't obvious

### 6. Dependencies
- Did you add a dependency for something achievable in a few lines?
- Are you using a heavy library where a lighter alternative exists?
- Can any new dependencies be dev-only?

## How to Run

1. Get the list of changed files:

```bash
git diff --name-only origin/main
```

2. Read each changed file and apply the checks above

3. Make fixes, keeping changes minimal — don't refactor code you didn't touch

4. Run tests and type-check after simplification to ensure nothing broke

## Rules

- Only simplify code YOU changed — don't touch unrelated code
- Don't add docstrings, comments, or type annotations to unchanged code
- If simplification changes behavior, make sure tests cover it
- Prefer deletion over modification — less code = less bugs
- When in doubt, keep it simple — the right amount of complexity is the minimum needed
