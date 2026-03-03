---
name: blocked
description: Signal that you need human input to continue. Creates a structured blocked file, commits it, and stops work. Use when requirements are unclear, you need a business/architectural decision, or you're missing credentials or access.
user_invocable: true
---

# blocked

Use this when you cannot continue without human input. This is the ONLY way to ask the developer a question in the autonomous agent workflow.

## When to Use

- Requirements are ambiguous or incomplete
- You need a business decision (pricing, copy, behavior choices)
- Missing credentials, API keys, or third-party access
- Architectural choices that need stakeholder approval
- You've hit a bug in a dependency or infrastructure you can't work around

## What to Do

1. Determine the issue identifier. Check for environment variable `$IDENTIFIER`, or extract it from the current branch name (e.g., `agent/ENG-123` → `ENG-123`), or ask the user.

2. Create the blocked file with your questions:

```bash
mkdir -p .claude/agent-blocked
```

3. Write `.claude/agent-blocked/<IDENTIFIER>.md` with this structure:

```markdown
# Blocked: <IDENTIFIER>

## Questions

1. [Specific, actionable question]
2. [Another question if needed]

## Context

[What you've done so far and why you're stuck]

## What I Need to Continue

[Exactly what information or decision you need]
```

4. If you have partial work done, commit it together with the blocked file:

```bash
git add -A
git commit -m "wip: partial implementation of <IDENTIFIER>, blocked on questions"
```

5. If no partial work, commit just the blocked file:

```bash
git add .claude/agent-blocked/<IDENTIFIER>.md
git commit -m "chore: agent blocked on <IDENTIFIER> — needs human input"
```

6. **STOP IMMEDIATELY** — do not continue working, do not guess at answers, do not try workarounds.

## Rules

- Be specific in your questions — "what should the pricing be?" is better than "I have questions"
- Include enough context that the developer can answer without reading all your code
- One blocked file per issue — if you have multiple questions, put them all in one file
- Do NOT write questions to stdout only — they must be in the file
- Do NOT continue working after creating the blocked file
