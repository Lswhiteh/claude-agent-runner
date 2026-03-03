#!/bin/bash
# block-destructive.sh — PreToolUse:Bash guardrail hook
#
# Blocks dangerous commands when running in agent mode (CLAUDE_AGENT_MODE=1).
# No-op in interactive sessions.
#
# Install: symlink to ~/.claude/hooks/ and register in settings.json
# Test: echo '{"tool_input":{"command":"rm -rf /"}}' | CLAUDE_AGENT_MODE=1 bash hooks/block-destructive.sh

set -uo pipefail

# Only active in agent mode
if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat)

# Extract command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Strip quoted strings and heredoc bodies to avoid false positives
# Replace single-quoted strings with placeholder
STRIPPED=$(echo "$COMMAND" | sed "s/'[^']*'/__QUOTED__/g")
# Replace double-quoted strings with placeholder
STRIPPED=$(echo "$STRIPPED" | sed 's/"[^"]*"/__QUOTED__/g')
# Remove heredoc bodies (everything between <<EOF and EOF)
STRIPPED=$(echo "$STRIPPED" | sed '/<<.*EOF/,/^EOF$/d')

deny() {
  local REASON="$1"
  echo "{\"hookSpecificOutput\": {\"permissionDecision\": \"deny\", \"reason\": \"$REASON\"}}"
  exit 0
}

# --- Destructive filesystem operations ---

# rm -rf (except safe dirs: node_modules, dist, .next, .turbo, coverage, __pycache__, build)
if echo "$STRIPPED" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force|-[a-zA-Z]*f[a-zA-Z]*r)\s'; then
  # Check if targeting a safe directory
  if ! echo "$STRIPPED" | grep -qE 'rm\s+.*\s(node_modules|dist|\.next|\.turbo|coverage|__pycache__|build|\.cache|tmp|\.temp)\b'; then
    deny "rm -rf is blocked in agent mode (safe dirs: node_modules, dist, .next, .turbo, coverage, build)"
  fi
fi

# --- Destructive git operations ---

if echo "$STRIPPED" | grep -qE 'git\s+push\s+.*--force'; then
  deny "git push --force is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE 'git\s+push\s+.*-f\b'; then
  deny "git push -f is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE 'git\s+reset\s+--hard'; then
  deny "git reset --hard is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f'; then
  deny "git clean -f is blocked in agent mode"
fi

# --- Destructive SQL operations ---

if echo "$STRIPPED" | grep -qiE '\bDROP\s+(TABLE|DATABASE)\b'; then
  deny "DROP TABLE/DATABASE is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qiE '\bTRUNCATE\s+TABLE\b'; then
  deny "TRUNCATE TABLE is blocked in agent mode"
fi

# --- Dangerous system operations ---

if echo "$STRIPPED" | grep -qE 'chmod\s+777'; then
  deny "chmod 777 is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE 'curl\s.*\|\s*bash'; then
  deny "curl | bash is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE 'wget\s.*\|\s*bash'; then
  deny "wget | bash is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE '\bdd\s+.*of=/dev/'; then
  deny "dd to device is blocked in agent mode"
fi

if echo "$STRIPPED" | grep -qE '\bmkfs\b'; then
  deny "mkfs is blocked in agent mode"
fi

# Command allowed
exit 0
