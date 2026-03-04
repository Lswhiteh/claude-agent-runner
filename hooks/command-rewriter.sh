#!/bin/bash
# command-rewriter.sh — PreToolUse:Bash hook
#
# Rewrites `npm install <packages>` to include --save-exact when missing.
# Only fires for package install commands, not bare `npm install` or `npm ci`.
#
# Gate: CLAUDE_AGENT_MODE=1
#
# Test: echo '{"tool_input":{"command":"npm install lodash"}}' | CLAUDE_AGENT_MODE=1 bash hooks/command-rewriter.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Match: npm install <packages> without --save-exact
# Skip: bare `npm install`, `npm ci`, already has --save-exact
if echo "$COMMAND" | grep -qE '\bnpm\s+install\s+[^-]'; then
  if ! echo "$COMMAND" | grep -qE '\-\-save-exact'; then
    # Rewrite: insert --save-exact after `npm install`
    REWRITTEN=$(echo "$COMMAND" | sed -E 's/(npm[[:space:]]+install)/\1 --save-exact/')
    cat <<EOF
{"hookSpecificOutput": {"updatedInput": {"command": "$REWRITTEN"}}}
EOF
  fi
fi

exit 0
