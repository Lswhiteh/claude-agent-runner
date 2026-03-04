#!/bin/bash
# stop-gate.sh — Stop event hook
#
# Blocks agent from finishing if no CI/test evidence is found in the
# conversation transcript. Prevents agents from declaring "done"
# without running tests.
#
# Gate: CLAUDE_AGENT_MODE=1
# Uses stop_hook_active guard to prevent infinite loops.
#
# Test: echo '{"transcript_path":"/tmp/test-transcript.jsonl"}' | CLAUDE_AGENT_MODE=1 bash hooks/stop-gate.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

# Prevent infinite loops — if this hook already fired, don't block again
if [ "${CLAUDE_STOP_HOOK_ACTIVE:-}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# If no transcript available, allow stop (fail open)
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

# Check for evidence of CI/test runs in the transcript
# Look for common test runner invocations in Bash commands
has_test_evidence() {
  grep -qE '(ci-gate|npm\s+test|npx\s+vitest|npx\s+jest|pytest|cargo\s+test|go\s+test|pnpm\s+test|yarn\s+test|make\s+test|bun\s+test)' "$1" 2>/dev/null
}

if has_test_evidence "$TRANSCRIPT"; then
  exit 0
fi

# No test evidence found — block the stop
export CLAUDE_STOP_HOOK_ACTIVE=1
cat <<EOF
{"decision": "block", "reason": "Run CI checks (ci-gate, npm test, pytest, cargo test, etc.) before finishing. No test/CI evidence found in this session."}
EOF

exit 0
