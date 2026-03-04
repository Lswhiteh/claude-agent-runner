#!/bin/bash
# task-validator.sh — TaskCompleted hook
#
# Blocks task completion if no CI/test evidence is found in the
# conversation transcript. Uses exit 2 + stderr to block.
#
# Gate: CLAUDE_AGENT_MODE=1
#
# Test: echo '{"transcript_path":"/tmp/test-transcript.jsonl"}' | CLAUDE_AGENT_MODE=1 bash hooks/task-validator.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# If no transcript available, allow completion (fail open)
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

# Check for evidence of CI/test runs in the transcript
has_test_evidence() {
  grep -qE '(ci-gate|npm\s+test|npx\s+vitest|npx\s+jest|pytest|cargo\s+test|go\s+test|pnpm\s+test|yarn\s+test|make\s+test|bun\s+test)' "$1" 2>/dev/null
}

if has_test_evidence "$TRANSCRIPT"; then
  exit 0
fi

# No test evidence — block task completion
echo "Cannot mark task as completed: no test/CI evidence found. Run ci-gate or your test suite first." >&2
exit 2
