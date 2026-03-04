#!/bin/bash
# rtk-failure-hint.sh — PostToolUseFailure:Bash hook
#
# When an RTK-filtered command fails, suggests re-running with `rtk proxy`
# to get the full unfiltered output for debugging.
#
# No gate — useful in both agent and interactive mode.
#
# Test: echo '{"tool_input":{"command":"rtk next build"}}' | bash hooks/rtk-failure-hint.sh

set -uo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only trigger for rtk commands that aren't already using proxy
if [[ "$COMMAND" == rtk\ * ]] && [[ "$COMMAND" != rtk\ proxy\ * ]]; then
  # Extract the subcommand after "rtk "
  SUBCMD="${COMMAND#rtk }"
  cat <<EOF
{"hookSpecificOutput": {"additionalContext": "This RTK-filtered command failed. Re-run with \`rtk proxy ${SUBCMD}\` to see the full unfiltered output for debugging."}}
EOF
fi

exit 0
