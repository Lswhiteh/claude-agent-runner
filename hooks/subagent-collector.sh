#!/bin/bash
# subagent-collector.sh — SubagentStop hook
#
# Logs subagent completions for orchestrated workers.
# Appends a JSONL entry with timestamp, agent_id, agent_type, and summary.
#
# Gate: CLAUDE_AGENT_SCOPED=1 (orchestrated workers only)
# Pure logging, no blocking.
#
# Test: echo '{"agent_id":"abc123","agent_type":"Explore","summary":"Found 3 files"}' | CLAUDE_AGENT_SCOPED=1 bash hooks/subagent-collector.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_SCOPED:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)
SUMMARY=$(echo "$INPUT" | jq -r '.summary // empty' 2>/dev/null)

LOG_DIR=".claude/orchestrator"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg ts "$TIMESTAMP" \
  --arg id "$AGENT_ID" \
  --arg type "$AGENT_TYPE" \
  --arg summary "$SUMMARY" \
  '{timestamp: $ts, agent_id: $id, agent_type: $type, summary: $summary}' \
  >> "$LOG_DIR/subagent-log.jsonl"

exit 0
