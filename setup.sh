#!/bin/bash
# setup.sh — Install claude-agent-runner components
# Usage: git clone https://github.com/Lswhiteh/claude-agent-runner.git && cd claude-agent-runner && ./setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Setting up claude-agent-runner from: $REPO_DIR"

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

# Register hooks in settings.json
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
  for HOOK_NAME in block-destructive.sh scope-guard.sh; do
    HOOK_PATH="$HOME/.claude/hooks/$HOOK_NAME"
    if ! jq -e '.hooks[] | select(.command == "'"$HOOK_PATH"'")' "$SETTINGS" >/dev/null 2>&1; then
      HOOK_ENTRY="{\"type\": \"preToolUse\", \"matcher\": \"Bash\", \"command\": \"$HOOK_PATH\"}"
      jq ".hooks = (.hooks // []) + [$HOOK_ENTRY]" "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
      echo "  Registered $HOOK_NAME in settings.json"
    else
      echo "  Skipped: $HOOK_NAME already registered in settings.json"
    fi
  done
else
  echo "  WARNING: Could not register hooks — settings.json not found or jq not installed"
  echo "  Manually add to ~/.claude/settings.json hooks array:"
  echo "    {\"type\": \"preToolUse\", \"matcher\": \"Bash\", \"command\": \"$HOME/.claude/hooks/block-destructive.sh\"}"
  echo "    {\"type\": \"preToolUse\", \"matcher\": \"Bash\", \"command\": \"$HOME/.claude/hooks/scope-guard.sh\"}"
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

# Create secrets.env placeholder if missing
SECRETS_FILE="$HOME/.config/claude-agents/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
  cat > "$SECRETS_FILE" << 'SECRETS'
# Claude Agent Runner secrets — fill in your API keys
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
echo "  ~/.local/bin/              ← claude-agent-runner, ci-gate"
echo "  ~/.claude/hooks/           ← block-destructive.sh, scope-guard.sh (guardrails)"
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
echo "     */5 * * * * source \$HOME/.config/claude-agents/secrets.env && \$HOME/.local/bin/claude-agent-runner >> \$HOME/.config/claude-agents/cron.log 2>&1"
echo "     CRON"
echo ""
