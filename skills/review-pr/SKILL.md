---
name: review-pr
description: Review a pull request for correctness, security, performance, and code quality. Checks diff, runs tests, identifies risks, and posts structured feedback. Use with a PR number or URL.
user_invocable: true
---

# review-pr

Review a pull request thoroughly. The argument should be a PR number or URL.

## Step 1: Gather Context

```bash
# Get PR details
gh pr view <PR> --json title,body,baseRefName,headRefName,files,additions,deletions

# Get the full diff
gh pr diff <PR>

# Check CI status
gh pr checks <PR>
```

## Step 2: Read Changed Files

For each changed file, read the FULL file (not just the diff) to understand context. Pay attention to:

- What the file does in the broader architecture
- Whether the change is consistent with existing patterns
- Whether imports/exports are correct

## Step 3: Review Checklist

### Correctness
- Does the code do what the PR description says?
- Are edge cases handled? (null, empty, boundary values)
- Are error paths correct? (what happens when things fail)
- Are race conditions possible? (async operations, shared state)

### Security
- Injection attacks (SQL, command, template)
- XSS (unsanitized user input in rendered output)
- Auth/authz gaps (missing permission checks, exposed endpoints)
- Secrets (hardcoded keys, tokens in code)
- User-controlled URLs in server-side requests (SSRF)

### Performance
- N+1 queries (loops with DB calls)
- Missing indexes for new queries
- Large payloads (unbounded queries, missing pagination)
- Memory leaks (unclosed connections, missing cleanup)

### Data Flow
- Are types correct end-to-end? (DB → API → UI)
- Are database migrations reversible?
- Is data validated at the boundary?
- Are null/undefined states handled?

### Code Quality
- Naming clarity
- Dead code or unused imports
- Overly complex logic that could be simplified
- Test coverage for new behavior

## Step 4: Run Tests Locally

```bash
gh pr checkout <PR>
# Run the project's test suite and CI checks
ci-gate .
```

## Step 5: Post Review

Categorize findings by severity:

- **Blocking**: Must fix before merge (bugs, security issues, data loss risks)
- **Important**: Should fix, but not a showstopper
- **Nit**: Style/preference, take it or leave it

```bash
gh pr review <PR> --comment --body "$(cat <<'EOF'
## Review Summary

[1-2 sentence overall assessment]

### Blocking
- [ ] [Issue with file:line reference]

### Important
- [ ] [Issue description]

### Nits
- [Suggestion]

### What looks good
- [Positive callout]
EOF
)"
```

## Rules

- Always read the full file, not just the diff — context matters
- Don't nitpick style when there's a linter/formatter configured
- Praise good work — reviews shouldn't be only negative
- If you're unsure about something, ask rather than block
- Focus on bugs and security over style preferences
