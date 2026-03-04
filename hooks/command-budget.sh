#!/bin/bash
# command-budget.sh — PreToolUse:Bash hook
#
# Tracks the number of Bash tool calls per session and denies when
# a configurable budget is exceeded. Helps detect stuck agents.
#
# Gate: CLAUDE_AGENT_MODE=1
# Budget: $CLAUDE_AGENT_CMD_BUDGET (default 300)
#
# Test: echo '{"session_id":"test123","tool_input":{"command":"echo hi"}}' | CLAUDE_AGENT_MODE=1 bash hooks/command-budget.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

BUDGET="${CLAUDE_AGENT_CMD_BUDGET:-300}"
COUNTER_FILE="/tmp/claude-agent-budget-${SESSION_ID}"

# Atomic increment
COUNT=1
if [ -f "$COUNTER_FILE" ]; then
  PREV=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  COUNT=$((PREV + 1))
fi
echo "$COUNT" > "$COUNTER_FILE"

if [ "$COUNT" -gt "$BUDGET" ]; then
  cat <<EOF
{"hookSpecificOutput": {"permissionDecision": "deny", "reason": "Agent has executed ${COUNT} commands (budget: ${BUDGET}). The agent may be stuck in a loop. Review logs and restart if needed."}}
EOF
fi

exit 0
