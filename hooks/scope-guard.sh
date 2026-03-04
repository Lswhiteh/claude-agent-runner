#!/bin/bash
# scope-guard.sh — PreToolUse:Bash hook for scoped workers
#
# Enforces file write scope when CLAUDE_AGENT_SCOPED=1.
# Reads scope from the subtask JSON file at $CLAUDE_AGENT_SCOPE_FILE.
# Allows reads anywhere, blocks writes outside scope.
#
# No-op when CLAUDE_AGENT_SCOPED is not set.
#
# Test: echo '{"tool_input":{"command":"echo hi > /outside/file.ts"}}' | \
#   CLAUDE_AGENT_SCOPED=1 CLAUDE_AGENT_SCOPE_FILE=subtask.json bash hooks/scope-guard.sh

set -uo pipefail

# Only active in scoped agent mode
if [ "${CLAUDE_AGENT_SCOPED:-}" != "1" ]; then
  exit 0
fi

# Must have a scope file
SCOPE_FILE="${CLAUDE_AGENT_SCOPE_FILE:-}"
if [ -z "$SCOPE_FILE" ] || [ ! -f "$SCOPE_FILE" ]; then
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat)

# Extract the tool being used and the command
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# For non-Bash tools, check Edit/Write file_path
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

deny() {
  local REASON="$1"
  echo "{\"hookSpecificOutput\": {\"permissionDecision\": \"deny\", \"reason\": \"$REASON\"}}"
  exit 0
}

# Load scope arrays from subtask JSON
SCOPE_PATTERNS=$(jq -r '.scope[]? // empty' "$SCOPE_FILE" 2>/dev/null)
if [ -z "$SCOPE_PATTERNS" ]; then
  # No scope defined — allow everything (shouldn't happen but be safe)
  exit 0
fi

# Check if a path matches any scope pattern
path_in_scope() {
  local CHECK_PATH="$1"

  # Normalize: strip leading ./ if present
  CHECK_PATH="${CHECK_PATH#./}"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    pattern="${pattern#./}"

    # Exact match
    if [ "$CHECK_PATH" = "$pattern" ]; then
      return 0
    fi

    # Directory prefix match (pattern is a dir, path is under it)
    # Strip trailing slash for comparison
    local clean_pattern="${pattern%/}"
    if [[ "$CHECK_PATH" == "${clean_pattern}/"* ]]; then
      return 0
    fi

    # Glob match using bash pattern matching
    # shellcheck disable=SC2254
    if [[ "$CHECK_PATH" == $pattern ]]; then
      return 0
    fi
  done <<< "$SCOPE_PATTERNS"

  return 1
}

# --- Check Edit/Write tool file_path ---
if [ -n "$FILE_PATH" ]; then
  if ! path_in_scope "$FILE_PATH"; then
    deny "SCOPE GUARD: You are scoped to specific files for this subtask. '${FILE_PATH}' is outside your scope. Document the needed change in .claude/orchestrator/scope-overflow report instead."
  fi
  exit 0
fi

# --- Check Bash commands for file writes ---
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Extract potential file write targets from common patterns
# We check: redirect (>), tee, mv, cp, sed -i, write commands
# But NOT: read-only commands (cat, head, grep, etc.)

check_write_target() {
  local TARGET="$1"
  # Skip if target is /dev/null or a pipe
  [[ "$TARGET" == "/dev/null" ]] && return 0
  [[ "$TARGET" == "-" ]] && return 0
  # Skip orchestrator state/overflow files (always allowed)
  [[ "$TARGET" == *".claude/orchestrator/"* ]] && return 0
  # Skip agent report files (always allowed)
  [[ "$TARGET" == *".claude/agent-reports/"* ]] && return 0
  # Skip agent blocked files (always allowed)
  [[ "$TARGET" == *".claude/agent-blocked/"* ]] && return 0
  # Skip git operations (commit messages etc)
  [[ "$TARGET" == *".git/"* ]] && return 0

  if ! path_in_scope "$TARGET"; then
    deny "SCOPE GUARD: You are scoped to specific files for this subtask. Write to '${TARGET}' is outside your scope. Document the needed change in .claude/orchestrator/scope-overflow report instead."
  fi
}

# Detect redirect targets: > file, >> file
while IFS= read -r target; do
  [ -n "$target" ] && check_write_target "$target"
done < <(echo "$COMMAND" | grep -oE '>{1,2}\s*[^ |;&]+' | sed 's/^>*[[:space:]]*//')

# Detect sed -i targets
if echo "$COMMAND" | grep -qE '\bsed\s+.*-i'; then
  # Last argument(s) of sed -i are typically the file targets
  # This is a best-effort heuristic
  SED_FILES=$(echo "$COMMAND" | grep -oE '\bsed\s+.*' | awk '{for(i=NF;i>0;i--){if($i !~ /^-/ && $i !~ /^s[\\/]/ && $i !~ /^'\''/ && $i !~ /^"/){print $i; break}}}')
  [ -n "$SED_FILES" ] && check_write_target "$SED_FILES"
fi

# Detect tee targets
if echo "$COMMAND" | grep -qE '\btee\s'; then
  TEE_TARGET=$(echo "$COMMAND" | grep -oE '\btee\s+(-a\s+)?[^ |;&]+' | awk '{print $NF}')
  [ -n "$TEE_TARGET" ] && check_write_target "$TEE_TARGET"
fi

# Allow everything else (reads, git commands, test runners, etc.)
exit 0
