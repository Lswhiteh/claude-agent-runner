#!/bin/bash
# pre-compact.sh — PreCompact hook
#
# Saves a snapshot of current agent state before context compaction.
# Captures git diff stats, status, and recent log so the agent can
# recover context after compaction.
#
# Gate: CLAUDE_AGENT_MODE=1
# Non-blocking: PreCompact cannot prevent compaction.
#
# Test: echo '{}' | CLAUDE_AGENT_MODE=1 bash hooks/pre-compact.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

SNAPSHOT_DIR=".claude/agent-state"
mkdir -p "$SNAPSHOT_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT="$SNAPSHOT_DIR/compact-snapshot-${TIMESTAMP}.md"

{
  echo "# Pre-compaction snapshot — ${TIMESTAMP}"
  echo ""
  echo "## Git diff --stat"
  git diff --stat 2>/dev/null || echo "(no diff)"
  echo ""
  echo "## Staged changes"
  git diff --cached --stat 2>/dev/null || echo "(none)"
  echo ""
  echo "## Git status"
  git status --short 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## Recent commits"
  git log --oneline -10 2>/dev/null || echo "(unavailable)"
} > "$SNAPSHOT" 2>/dev/null

exit 0
