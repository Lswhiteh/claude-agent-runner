---
name: agent-report
description: Generate a structured implementation report at .claude/agent-reports/<IDENTIFIER>.md. Focuses on decisions, rationale, and risks — not restating the diff. Required after every agent implementation.
user_invocable: true
---

# agent-report

Create a structured report documenting your implementation. This is MANDATORY — the agent runner posts it to Linear for developer review.

**The purpose of this report is to capture context the diff cannot show.** A reviewer can read the diff to see what changed. Your report must explain WHY things changed, what alternatives were considered, and what risks remain.

## How to Use

1. Determine the issue identifier — check `$IDENTIFIER`, branch name (`agent/ENG-123`), or the task you're working on.

2. Create the report directory:

```bash
mkdir -p .claude/agent-reports
```

3. Write `.claude/agent-reports/<IDENTIFIER>.md` with this structure:

```markdown
# <IDENTIFIER>: <Title>

## Summary
[1-3 sentences: what problem this solves and how. Lead with WHY, not WHAT.]

## Decisions and rationale
[This is the most important section. For each non-obvious decision:]
- **[Decision]**: [What you chose] — [What alternatives you considered] — [Why this one won]

[Examples of good entries:]
- **Used middleware pattern over route-level checks**: Considered per-route auth guards but middleware gives one enforcement point. Route-level would need duplication across 12 endpoints and risks someone forgetting one.
- **Kept sync DB writes instead of moving to a queue**: A queue would be more resilient but adds infrastructure complexity for a feature that handles ~10 writes/minute. Not worth it yet.

[If you made zero interesting decisions, say so — don't invent rationale.]

## Files changed
- `path/to/file.ts` — [WHY this file needed to change, not what the diff shows]
- `path/to/other.ts` — [WHY]

## Risks or follow-ups
[Be honest. Hidden problems are worse than known ones.]
- [Edge cases you didn't cover and WHY (time, complexity, out of scope)]
- [Trade-offs you made — what you gained and what you gave up]
- [Technical debt introduced and under what conditions it becomes a problem]
- [Performance considerations if applicable]

[If there are no risks, say "None identified" — don't pad this section.]

## Tests
- [What was tested and why those scenarios matter]
- [What ISN'T tested and why (too complex to mock, infrastructure-dependent, etc.)]
- [Test file locations]
```

4. If CI failed and you fixed errors, add a CI Fix section:

```markdown
## CI fix attempts
### Attempt N
- **Errors**: [root cause, not just the error message]
- **Fix**: [what you changed and why that was the right fix]
- **Result**: PASS/FAIL
```

5. Commit the report:

```bash
git add .claude/agent-reports/<IDENTIFIER>.md
git commit -m "docs: add agent report for <IDENTIFIER>"
```

## Rules

- **"Why" over "what"** — every section should explain rationale, not restate the diff
- **Be honest about risks and gaps** — a known risk is manageable, a hidden one isn't
- **List ALL files changed** — but describe why, not what
- **Don't pad** — if a section has nothing meaningful, say so in one line and move on
- **Keep it concise** — this is a review aid, not a novel. Dense and useful > long and thorough
