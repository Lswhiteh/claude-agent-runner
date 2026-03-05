# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Add Claude Code Hooks Suite to claude-agent-runner

## Context

The agent runner currently has only 2 hooks (block-destructive.sh, scope-guard.sh) — both PreToolUse:Bash guards. Claude Code supports 16 hook event types with rich control (blocking, context injection, input rewriting, async execution). This plan adds 9 new hooks across 7 event types to improve agent safety, observability, and self-correction. It also fixes the broken settings.json registra...

### Prompt 2

push

### Prompt 3

make PRs draft PRs, humans will mark as ready for review

### Prompt 4

PR names should have the ticket but also brief description

### Prompt 5

[Request interrupted by user]

### Prompt 6

branch names, that is

### Prompt 7

Do we have a way to visualize/trace what the agent did/decided to do at any given step?

### Prompt 8

[Request interrupted by user]

### Prompt 9

Especially with the more complex orchestration tickets that would be useful

### Prompt 10

JSONL with a UI would be great

### Prompt 11

[Request interrupted by user for tool use]

