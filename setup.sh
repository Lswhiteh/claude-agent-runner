#!/bin/bash
# setup.sh — Install car (Claude Agent Runner) components
# Usage: git clone https://github.com/Lswhiteh/claude-agent-runner.git && cd claude-agent-runner && ./setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Setting up car (Claude Agent Runner) from: $REPO_DIR"

# --- bin/ → ~/.local/bin/ ---
echo ""
echo "=== Scripts ==="
mkdir -p "$HOME/.local/bin"
for script in "$REPO_DIR/bin/"*; do
  [ -f "$script" ] || continue
  NAME=$(basename "$script")
  TARGET="$HOME/.local/bin/$NAME"
  if [ -L "$TARGET" ] || [ -f "$TARGET" ]; then
    echo "  Replacing: $TARGET"
    rm -f "$TARGET"
  fi
  ln -s "$script" "$TARGET"
  chmod +x "$script"
  echo "  Linked: $NAME → $TARGET"
done

# --- hooks/ → ~/.claude/hooks/ ---
echo ""
echo "=== Hooks ==="
mkdir -p "$HOME/.claude/hooks"
for hook in "$REPO_DIR/hooks/"*; do
  [ -f "$hook" ] || continue
  NAME=$(basename "$hook")
  TARGET="$HOME/.claude/hooks/$NAME"
  if [ -L "$TARGET" ] || [ -f "$TARGET" ]; then
    echo "  Replacing: $TARGET"
    rm -f "$TARGET"
  fi
  ln -s "$hook" "$TARGET"
  chmod +x "$hook"
  echo "  Linked: $NAME → $TARGET"
done

# Register hooks in settings.json (correct nested format)
SETTINGS="$HOME/.claude/settings.json"
HOOKS_DIR="$HOME/.claude/hooks"

# register_hook <event> <matcher> <hook_file> [async]
# Adds a hook entry to settings.json using the correct nested format:
#   hooks.<Event>[{matcher, hooks:[{type, command}]}]
# Idempotent: skips if command path already present under the event.
register_hook() {
  local EVENT="$1"
  local MATCHER="$2"
  local HOOK_FILE="$3"
  local ASYNC="${4:-false}"
  local HOOK_PATH="$HOOKS_DIR/$HOOK_FILE"

  # Check if already registered under this event
  if jq -e ".hooks.\"$EVENT\"[]?.hooks[]? | select(.command == \"$HOOK_PATH\")" "$SETTINGS" >/dev/null 2>&1; then
    echo "  Skipped: $HOOK_FILE already registered under $EVENT"
    return 0
  fi

  # Build the hook entry
  local HOOK_OBJ
  if [ "$ASYNC" = "true" ]; then
    HOOK_OBJ=$(jq -n --arg cmd "$HOOK_PATH" '{type: "command", command: $cmd, async: true}')
  else
    HOOK_OBJ=$(jq -n --arg cmd "$HOOK_PATH" '{type: "command", command: $cmd}')
  fi

  # Check if a matcher group already exists for this event+matcher
  local MATCHER_EXISTS
  MATCHER_EXISTS=$(jq -e ".hooks.\"$EVENT\"[]? | select(.matcher == \"$MATCHER\")" "$SETTINGS" 2>/dev/null || true)

  if [ -n "$MATCHER_EXISTS" ]; then
    # Append to existing matcher group's hooks array
    jq "(.hooks.\"$EVENT\"[] | select(.matcher == \"$MATCHER\") | .hooks) += [$HOOK_OBJ]" \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  else
    # Create new matcher group
    local GROUP
    GROUP=$(jq -n --arg m "$MATCHER" --argjson h "[$HOOK_OBJ]" '{matcher: $m, hooks: $h}')
    jq ".hooks.\"$EVENT\" = (.hooks.\"$EVENT\" // []) + [$GROUP]" \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi

  echo "  Registered $HOOK_FILE under $EVENT (matcher: ${MATCHER:-\"(all)\"})"
}

if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
  # Ensure hooks object exists
  if ! jq -e '.hooks' "$SETTINGS" >/dev/null 2>&1; then
    jq '. + {hooks: {}}' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi

  # Migrate old flat-format hooks if present (pre-v2 format)
  if jq -e '.hooks | type == "array"' "$SETTINGS" >/dev/null 2>&1; then
    echo "  Migrating old flat-format hooks to nested format..."
    jq '.hooks = {}' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi

  # --- PreToolUse:Bash hooks ---
  register_hook "PreToolUse" "Bash" "block-destructive.sh"
  register_hook "PreToolUse" "Bash" "scope-guard.sh"
  register_hook "PreToolUse" "Bash" "command-budget.sh"
  register_hook "PreToolUse" "Bash" "command-rewriter.sh"

  # --- PostToolUse:Edit|Write (async) ---
  register_hook "PostToolUse" "Edit|Write" "auto-lint.sh" "true"

  # --- PostToolUseFailure:Bash ---
  register_hook "PostToolUseFailure" "Bash" "rtk-failure-hint.sh"

  # --- SessionStart ---
  register_hook "SessionStart" "" "session-context.sh"

  # --- Stop ---
  register_hook "Stop" "" "stop-gate.sh"

  # --- SubagentStop ---
  register_hook "SubagentStop" "" "subagent-collector.sh"

  # --- TaskCompleted ---
  register_hook "TaskCompleted" "" "task-validator.sh"

  # --- PreCompact ---
  register_hook "PreCompact" "" "pre-compact.sh"
else
  echo "  WARNING: Could not register hooks — settings.json not found or jq not installed"
  echo "  Create ~/.claude/settings.json with {\"hooks\": {}} and re-run setup.sh"
fi

# --- skills/ → ~/.claude/skills/ ---
echo ""
echo "=== Skills ==="
mkdir -p "$HOME/.claude/skills"
for skill_dir in "$REPO_DIR/skills/"*/; do
  [ -d "$skill_dir" ] || continue
  NAME=$(basename "$skill_dir")
  TARGET="$HOME/.claude/skills/$NAME"
  if [ -L "$TARGET" ]; then
    rm -f "$TARGET"
  elif [ -d "$TARGET" ]; then
    echo "  Skipped: $TARGET already exists (not a symlink)"
    continue
  fi
  ln -s "$skill_dir" "$TARGET"
  echo "  Linked: $NAME → $TARGET"
done

# --- config/ → ~/.config/claude-agents/ ---
echo ""
echo "=== Config ==="
mkdir -p "$HOME/.config/claude-agents"

CONFIG_TARGET="$HOME/.config/claude-agents/config.json"
if [ ! -f "$CONFIG_TARGET" ]; then
  cp "$REPO_DIR/config/config.example.json" "$CONFIG_TARGET"
  echo "  Created: $CONFIG_TARGET (from example — edit with your repos)"
else
  echo "  Skipped: $CONFIG_TARGET already exists"
fi

mkdir -p "$HOME/.config/claude-agents/logs"
mkdir -p "$HOME/.config/claude-agents/locks"
mkdir -p "$HOME/.config/claude-agents/traces"

# Create secrets.env placeholder if missing
SECRETS_FILE="$HOME/.config/claude-agents/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
  cat > "$SECRETS_FILE" << 'SECRETS'
# CAR (Claude Agent Runner) secrets — fill in your API keys
# This file is sourced by the agent runner and cron jobs
# Permissions: 600 (owner-only read/write)

# export ANTHROPIC_API_KEY=sk-ant-...
# export LINEAR_API_KEY_EXAMPLE=lin_api_...
# export SLACK_WEBHOOK_EXAMPLE=https://hooks.slack.com/services/...
SECRETS
  chmod 600 "$SECRETS_FILE"
  echo "  Created: $SECRETS_FILE (fill in your API keys)"
else
  echo "  Skipped: $SECRETS_FILE already exists"
fi

# --- summary ---
echo ""
echo "=== Done! ==="
echo ""
echo "What was set up:"
echo "  ~/.local/bin/              ← car, ci-gate, agent-trace"
echo "  ~/.claude/hooks/           ← 11 hooks (guardrails, linting, budget, context, ...)"
echo "  ~/.claude/skills/          ← agent skills (implement, orchestrate, scoped-worker, ...)"
echo "  ~/.config/claude-agents/   ← config, secrets, logs, locks"
echo ""
echo "Remaining manual steps:"
echo ""
echo "  1. Fill in API keys:"
echo "     nano ~/.config/claude-agents/secrets.env"
echo ""
echo "  2. Edit agent config with your repo paths:"
echo "     nano ~/.config/claude-agents/config.json"
echo ""
echo "  3. Optional: Install the cron job for autonomous agents:"
echo "     crontab -l 2>/dev/null | cat - <<'CRON' | crontab -"
echo "     PATH=/usr/local/bin:/usr/bin:/bin:\$HOME/.local/bin:/opt/homebrew/bin"
echo "     */5 * * * * source \$HOME/.config/claude-agents/secrets.env && \$HOME/.local/bin/car >> \$HOME/.config/claude-agents/cron.log 2>&1"
echo "     CRON"
echo ""
