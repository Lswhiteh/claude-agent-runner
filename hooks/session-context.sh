#!/bin/bash
# session-context.sh — SessionStart hook
#
# Injects agent identity context at session start.
# Reads env vars exported by the agent runner and provides them
# as additionalContext so the agent knows its identity.
#
# Gate: CLAUDE_AGENT_MODE=1
#
# Test: CLAUDE_AGENT_MODE=1 CLAUDE_AGENT_ISSUE_ID=ENG-123 CLAUDE_AGENT_REPO=myapp \
#   CLAUDE_AGENT_BRANCH=agent/ENG-123 CLAUDE_AGENT_WORKTREE=/tmp/wt \
#   echo '{}' | bash hooks/session-context.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

# Consume stdin (required by hook protocol)
cat > /dev/null

ISSUE_ID="${CLAUDE_AGENT_ISSUE_ID:-}"
REPO="${CLAUDE_AGENT_REPO:-}"
BRANCH="${CLAUDE_AGENT_BRANCH:-}"
WORKTREE="${CLAUDE_AGENT_WORKTREE:-}"

# Build context string
CONTEXT="Agent session context:"
[ -n "$ISSUE_ID" ] && CONTEXT="$CONTEXT\n- Issue: $ISSUE_ID"
[ -n "$REPO" ] && CONTEXT="$CONTEXT\n- Repo: $REPO"
[ -n "$BRANCH" ] && CONTEXT="$CONTEXT\n- Branch: $BRANCH"
[ -n "$WORKTREE" ] && CONTEXT="$CONTEXT\n- Worktree: $WORKTREE"

# Only output if we have at least one identity var
if [ -n "$ISSUE_ID" ] || [ -n "$REPO" ] || [ -n "$BRANCH" ]; then
  cat <<EOF
{"hookSpecificOutput": {"additionalContext": "$CONTEXT"}}
EOF
fi

# Persist env vars to CLAUDE_ENV_FILE if available
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -w "${CLAUDE_ENV_FILE:-/dev/null}" ]; then
  {
    [ -n "$ISSUE_ID" ] && echo "CLAUDE_AGENT_ISSUE_ID=$ISSUE_ID"
    [ -n "$REPO" ] && echo "CLAUDE_AGENT_REPO=$REPO"
    [ -n "$BRANCH" ] && echo "CLAUDE_AGENT_BRANCH=$BRANCH"
    [ -n "$WORKTREE" ] && echo "CLAUDE_AGENT_WORKTREE=$WORKTREE"
  } >> "$CLAUDE_ENV_FILE"
fi

exit 0
