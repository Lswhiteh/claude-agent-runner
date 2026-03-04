#!/bin/bash
# auto-lint.sh — PostToolUse:Edit|Write hook (async)
#
# Runs linter on files after Edit/Write tool calls.
# Detects lint config in cwd and runs the appropriate linter.
# Async: output delivered as context on next turn without blocking.
#
# Gate: CLAUDE_AGENT_MODE=1
#
# Test: echo '{"tool_input":{"file_path":"src/index.ts"}}' | CLAUDE_AGENT_MODE=1 bash hooks/auto-lint.sh

set -uo pipefail

if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

# Determine extension
EXT="${FILE_PATH##*.}"

LINT_OUTPUT=""

case "$EXT" in
  ts|tsx|js|jsx|mjs|cjs)
    # Check for eslint config
    if [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ] || [ -f "eslint.config.ts" ]; then
      LINT_OUTPUT=$(npx eslint --no-warn-ignored --max-warnings 0 "$FILE_PATH" 2>&1 | tail -20) || true
    fi
    ;;
  py)
    # Check for ruff config or pyproject.toml
    if command -v ruff &>/dev/null; then
      LINT_OUTPUT=$(ruff check "$FILE_PATH" 2>&1 | tail -20) || true
    fi
    ;;
esac

if [ -n "$LINT_OUTPUT" ]; then
  # Escape for JSON
  ESCAPED=$(echo "$LINT_OUTPUT" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput": {"additionalContext": "Auto-lint on ${FILE_PATH}:\n${LINT_OUTPUT}"}}
EOF
fi

exit 0
