---
name: agent-report
description: Generate a structured implementation report at .claude/agent-reports/<IDENTIFIER>.md. Documents what was implemented, files changed, decisions made, risks, and test coverage. Required after every agent implementation.
user_invocable: true
---

# agent-report

Create a structured report documenting what was implemented. This is MANDATORY — the agent runner posts it to Linear for developer review.

## How to Use

1. Determine the issue identifier — check `$IDENTIFIER`, branch name (`agent/ENG-123`), or the task you're working on.

2. Create the report directory:

```bash
mkdir -p .claude/agent-reports
```

3. Write `.claude/agent-reports/<IDENTIFIER>.md` with this structure:

```markdown
# <IDENTIFIER>: <Title>

## What was implemented
[1-3 sentence summary of the feature/fix/change]

## Files changed
- `path/to/file.ts` — [what changed and why]
- `path/to/other.ts` — [what changed and why]

## Decisions made
- [Decision 1]: [Why this approach was chosen over alternatives]
- [Decision 2]: [Rationale]

## Risks or follow-ups
- [Anything that needs human attention]
- [Technical debt introduced]
- [Edge cases not covered]
- [Performance considerations]

## Tests
- [What was tested]
- [Test file locations]
- [Coverage notes — what's covered, what isn't]

## CI gate results
- Type check: PASS/FAIL
- Tests: PASS/FAIL (X passing, Y failing)
- Build: PASS/FAIL
- Lint: PASS/FAIL
```

4. If CI failed and you were fixing errors, add a CI Fix section:

```markdown
## CI Fix Attempts
### Attempt N
- **Errors**: [what failed]
- **Fixes**: [what you changed]
- **Result**: PASS/FAIL
```

5. Commit the report:

```bash
git add .claude/agent-reports/<IDENTIFIER>.md
git commit -m "docs: add agent report for <IDENTIFIER>"
```

## Rules

- Be honest about risks and gaps — don't hide problems
- List ALL files changed, not just the main ones
- Include the actual CI gate results, not just "passed"
- If you had to make a judgment call, explain your reasoning
- Keep it concise — this is a review aid, not a novel
