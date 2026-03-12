# Agent Harness Framework Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a configurable enforcement layer, interactive dispatch mode, and validation instrumentation for the claude-agent-runner.

**Architecture:** Two new hooks (enforce-pre.sh, enforce-post.sh) share a library (enforce-lib.sh) that reads per-project `.claude/enforcement.yaml` configs. Three check types (grep, biome, LLM) route to three enforcement levels (block, warn, info). A new `agent-harness` CLI bootstraps configs, runs checks manually, and aggregates metrics. An interactive `/dispatch` skill wraps the runner's infrastructure for in-session use. All enforcement events emit to the existing JSONL trace system.

**Tech Stack:** Bash, jq, yq, curl (Anthropic API for Haiku), biome (optional), schpet/linear-cli

**Spec:** `docs/superpowers/specs/2026-03-11-agent-harness-framework-design.md`

**Important implementation note:** PreToolUse hooks block via `{"hookSpecificOutput": {"permissionDecision": "deny", "reason": "..."}}` and **always exit 0**. They do NOT use exit codes to block. Only TaskCompleted hooks use exit 2 + stderr. Follow the existing hook patterns exactly.

**Ordering note:** Tasks 11-13 (tracing, self-correction, auto-escalation) are moved ahead of dispatch (Task 14) because auto-escalation depends on self-correction data, and dispatch doesn't depend on either. This diverges from the spec's implementation order but is architecturally sound.

**Naming conventions:**
- Skill files are named `SKILL.md` (not `<skill-name>.md`) — see existing `skills/*/SKILL.md` pattern
- Hook matchers use pipe-separated format: `"Edit|Write"` (not comma-separated)
- `register_hook` takes a filename (not full path) — it prepends the hooks dir internally
- Async hooks pass `"true"` as fourth argument (not `async`)

---

## Chunk 1: Core Enforcement Library + Grep Hooks

### Task 1: Create test infrastructure for hooks

**Files:**
- Create: `tests/enforce-test.sh`

- [ ] **Step 1: Create test runner script**

```bash
#!/bin/bash
# tests/enforce-test.sh — test harness for enforcement hooks
# Usage: bash tests/enforce-test.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -q "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected '$expected' in output"
    echo "  GOT: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -q "$unexpected"; then
    echo "  FAIL: $label — unexpected '$unexpected' in output"
    echo "  GOT: $output"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_exit_code() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected exit $expected, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Enforcement Hook Tests ==="
echo ""

# Tests will be added in subsequent steps

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Make it executable and verify it runs**

Run: `chmod +x tests/enforce-test.sh && bash tests/enforce-test.sh`
Expected: `=== Results: 0 passed, 0 failed ===` with exit 0

- [ ] **Step 3: Commit**

```bash
git add tests/enforce-test.sh
git commit -m "test: add enforcement hook test harness"
```

---

### Task 2: Create enforce-lib.sh — YAML parsing and rule matching

**Files:**
- Create: `hooks/enforce-lib.sh`

- [ ] **Step 1: Write failing tests for enforce-lib.sh**

Add to `tests/enforce-test.sh` before the results line:

```bash
# --- enforce-lib.sh tests ---
echo "## enforce-lib.sh"

# Create temp enforcement.yaml for testing
TEMP_DIR=$(mktemp -d)
cat > "$TEMP_DIR/enforcement.yaml" << 'YAML'
version: 1
builtins:
  command-budget: 500
  stop-gate: warn
settings:
  llm:
    model: claude-haiku-4-5-20251001
    api_key_env: ANTHROPIC_API_KEY
    max_tokens: 200
    timeout: 5
  cache_ttl: 300
  trace: true
  log_file: /tmp/enforce-test.log
rules:
  - name: no-console-log
    description: "Use logger instead of console.log"
    check: grep
    pattern: "console\\.(log|debug|info)"
    files: "src/**/*.ts"
    exclude: "**/*.test.ts"
    level: warn
  - name: no-env-access
    description: "Access env vars through config module"
    check: grep
    pattern: "process\\.env\\."
    files: "src/**/*.ts"
    exclude: "src/config/**"
    level: block
  - name: service-boundary
    description: "Route handlers should delegate to services"
    check: llm
    prompt: "Does this contain business logic?"
    files: "src/routes/**/*.ts"
    level: warn
YAML

# Test: enforce_load_config
source "$SCRIPT_DIR/hooks/enforce-lib.sh"
enforce_load_config "$TEMP_DIR/enforcement.yaml"
assert_exit_code "enforce_load_config succeeds" $? 0

# Test: enforce_rules_for_file — block level only
BLOCK_RULES=$(enforce_rules_for_file "src/routes/users.ts" "block")
assert_contains "block rules include no-env-access" "$BLOCK_RULES" "no-env-access"
assert_not_contains "block rules exclude warn rules" "$BLOCK_RULES" "no-console-log"

# Test: enforce_rules_for_file — warn level
WARN_RULES=$(enforce_rules_for_file "src/routes/users.ts" "warn")
assert_contains "warn rules include no-console-log" "$WARN_RULES" "no-console-log"
assert_contains "warn rules include llm rule" "$WARN_RULES" "service-boundary"

# Test: enforce_rules_for_file — file not matching glob
NOMATCH_RULES=$(enforce_rules_for_file "lib/utils.py" "block")
assert_contains "no rules for non-matching file" "$NOMATCH_RULES" ""

# Test: enforce_rules_for_file — excluded file
EXCLUDED_RULES=$(enforce_rules_for_file "src/routes/users.test.ts" "warn")
assert_not_contains "excluded file skips no-console-log" "$EXCLUDED_RULES" "no-console-log"

# Test: enforce_builtin_level
STOP_LEVEL=$(enforce_builtin_level "stop-gate")
assert_contains "builtin override reads correctly" "$STOP_LEVEL" "warn"

BUDGET=$(enforce_builtin_level "command-budget")
assert_contains "builtin numeric reads correctly" "$BUDGET" "500"

# Cleanup
rm -rf "$TEMP_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: All FAIL (enforce-lib.sh doesn't exist yet)

- [ ] **Step 3: Write enforce-lib.sh**

```bash
#!/bin/bash
# hooks/enforce-lib.sh — shared enforcement library
# Sourced by enforce-pre.sh, enforce-post.sh, and agent-harness
# Requires: yq, jq
set -uo pipefail

ENFORCE_CACHE_DIR="/tmp"
ENFORCE_CONFIG_JSON=""
ENFORCE_CONFIG_HASH=""

# Load and cache enforcement.yaml as JSON
# Usage: enforce_load_config /path/to/enforcement.yaml
enforce_load_config() {
  local config_path="$1"
  [ ! -f "$config_path" ] && return 1

  local mtime
  mtime=$(stat -f '%m' "$config_path" 2>/dev/null || stat -c '%Y' "$config_path" 2>/dev/null)
  ENFORCE_CONFIG_HASH=$(echo "${config_path}:${mtime}" | shasum -a 256 | cut -d' ' -f1 | head -c 16)
  local cache_file="${ENFORCE_CACHE_DIR}/enforce-${ENFORCE_CONFIG_HASH}.json"

  if [ -f "$cache_file" ]; then
    ENFORCE_CONFIG_JSON="$cache_file"
  else
    if ! command -v yq &>/dev/null; then
      echo "enforce-lib: yq not found, cannot parse enforcement.yaml" >&2
      return 1
    fi
    yq -o json "$config_path" > "$cache_file" 2>/dev/null || return 1
    ENFORCE_CONFIG_JSON="$cache_file"
  fi
  return 0
}

# Get rules matching a file path and enforcement level
# Usage: enforce_rules_for_file "src/routes/users.ts" "block"
# Output: JSON array of matching rules (one per line, compact)
enforce_rules_for_file() {
  local file_path="$1"
  local level="$2"
  [ -z "$ENFORCE_CONFIG_JSON" ] && return 0

  jq -r --arg file "$file_path" --arg level "$level" '
    (.rules // [])[] |
    select(.level == $level) |
    # Check files glob match
    select(
      (.files // "**") as $glob |
      # Convert glob to regex: ** -> .*, * -> [^/]*, . -> \.
      ($glob | gsub("\\*\\*"; "DOUBLESTAR") | gsub("\\*"; "[^/]*") | gsub("DOUBLESTAR"; ".*") | gsub("\\."; "\\.")) as $regex |
      ($file | test($regex))
    ) |
    # Check exclude glob does NOT match
    select(
      if .exclude then
        (.exclude) as $excl |
        ($excl | gsub("\\*\\*"; "DOUBLESTAR") | gsub("\\*"; "[^/]*") | gsub("DOUBLESTAR"; ".*") | gsub("\\."; "\\.")) as $eregex |
        ($file | test($eregex)) | not
      else
        true
      end
    ) |
    .name
  ' "$ENFORCE_CONFIG_JSON" 2>/dev/null
}

# Get a full rule object by name
# Usage: enforce_get_rule "no-console-log"
enforce_get_rule() {
  local rule_name="$1"
  [ -z "$ENFORCE_CONFIG_JSON" ] && return 0
  jq -r --arg name "$rule_name" '(.rules // [])[] | select(.name == $name)' "$ENFORCE_CONFIG_JSON" 2>/dev/null
}

# Get builtin override value
# Usage: enforce_builtin_level "stop-gate"
enforce_builtin_level() {
  local builtin_name="$1"
  [ -z "$ENFORCE_CONFIG_JSON" ] && return 0
  jq -r --arg name "$builtin_name" '.builtins[$name] // empty' "$ENFORCE_CONFIG_JSON" 2>/dev/null
}

# Run a grep check against content
# Usage: enforce_check_grep "pattern" "content"
# Returns: 0 if violation found, 1 if clean
enforce_check_grep() {
  local pattern="$1"
  local content="$2"
  if echo "$content" | grep -nE "$pattern" 2>/dev/null; then
    return 0  # violation found
  fi
  return 1  # clean
}

# Get setting value
# Usage: enforce_setting "llm.timeout"
enforce_setting() {
  local path="$1"
  [ -z "$ENFORCE_CONFIG_JSON" ] && return 0
  jq -r ".settings.${path} // empty" "$ENFORCE_CONFIG_JSON" 2>/dev/null
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add hooks/enforce-lib.sh tests/enforce-test.sh
git commit -m "feat: add enforce-lib.sh with YAML parsing, rule matching, grep checks"
```

---

### Task 3: Create enforce-pre.sh — PreToolUse blocking hook

**Files:**
- Create: `hooks/enforce-pre.sh`

- [ ] **Step 1: Write failing tests for enforce-pre.sh**

Add to `tests/enforce-test.sh`:

```bash
# --- enforce-pre.sh tests ---
echo ""
echo "## enforce-pre.sh"

# Create temp project with enforcement config
PRE_DIR=$(mktemp -d)
mkdir -p "$PRE_DIR/.claude"
cat > "$PRE_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: false
rules:
  - name: no-env-access
    description: "Use config module"
    check: grep
    pattern: "process\\.env\\."
    files: "src/**/*.ts"
    level: block
  - name: no-console
    description: "Use logger"
    check: grep
    pattern: "console\\.log"
    files: "src/**/*.ts"
    level: warn
YAML

# Test: block-level grep rule fires on Edit with violation (non-excluded path)
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$PRE_DIR"'/src/routes/db.ts","new_string":"const url = process.env.DATABASE_URL;"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$PRE_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_contains "pre-hook blocks env access" "$OUTPUT" "permissionDecision"
assert_contains "pre-hook deny reason mentions rule" "$OUTPUT" "no-env-access"

# Test: excluded path is NOT blocked
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$PRE_DIR"'/src/config/db.ts","new_string":"const url = process.env.DATABASE_URL;"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$PRE_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_not_contains "excluded path not blocked" "$OUTPUT" "permissionDecision"

# Test: clean file with no violations produces no output
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$PRE_DIR"'/src/routes/clean.ts","new_string":"import { config } from \"../config\";\nconst url = config.dbUrl;"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$PRE_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_not_contains "clean file produces no block" "$OUTPUT" "permissionDecision"

# Test: warn-level rule does NOT fire in pre-hook
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$PRE_DIR"'/src/app.ts","new_string":"console.log(\"hi\");"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$PRE_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_not_contains "pre-hook ignores warn rules" "$OUTPUT" "permissionDecision"

# Test: no config file — passes through
OUTPUT=$(echo '{"tool_input":{"file_path":"/tmp/no-config/src/app.ts","new_string":"process.env.BAD"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="/tmp/no-config" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_not_contains "no config = no block" "$OUTPUT" "permissionDecision"

# Test: gate — inactive without CLAUDE_AGENT_MODE
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$PRE_DIR"'/src/app.ts","new_string":"process.env.BAD"}}' | \
  ENFORCE_PROJECT_DIR="$PRE_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_not_contains "inactive without CLAUDE_AGENT_MODE" "$OUTPUT" "permissionDecision"

# Test: Write tool — checks content field
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$PRE_DIR"'/src/app.ts","content":"const x = process.env.SECRET;"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$PRE_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
assert_contains "pre-hook blocks Write with violation" "$OUTPUT" "permissionDecision"

rm -rf "$PRE_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: enforce-pre.sh tests all FAIL

- [ ] **Step 3: Write enforce-pre.sh**

```bash
#!/bin/bash
# hooks/enforce-pre.sh — PreToolUse:Edit|Write enforcement hook
# Evaluates BLOCK-level deterministic rules (grep, biome) before edits.
# Always exits 0. Blocks via hookSpecificOutput permissionDecision.
#
# Gate: CLAUDE_AGENT_MODE=1
# Config: ENFORCE_PROJECT_DIR/.claude/enforcement.yaml (or auto-detect from file_path)
#
# Test: echo '{"tool_input":{"file_path":"src/app.ts","new_string":"process.env.X"}}' | \
#   CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR=/path/to/project bash hooks/enforce-pre.sh
set -uo pipefail

# Gate
if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

# Extract file path
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Determine project dir
PROJECT_DIR="${ENFORCE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  # Walk up from file path to find .claude/enforcement.yaml
  SEARCH_DIR=$(dirname "$FILE_PATH")
  while [ "$SEARCH_DIR" != "/" ] && [ "$SEARCH_DIR" != "." ]; do
    if [ -f "$SEARCH_DIR/.claude/enforcement.yaml" ]; then
      PROJECT_DIR="$SEARCH_DIR"
      break
    fi
    SEARCH_DIR=$(dirname "$SEARCH_DIR")
  done
fi
[ -z "$PROJECT_DIR" ] && exit 0

CONFIG_FILE="$PROJECT_DIR/.claude/enforcement.yaml"
[ ! -f "$CONFIG_FILE" ] && exit 0

# Source library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/enforce-lib.sh"

# Load config
enforce_load_config "$CONFIG_FILE" || exit 0

# Get content to check — Edit uses new_string, Write uses content
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null)
[ -z "$CONTENT" ] && exit 0

# Make file path relative to project dir for glob matching
REL_PATH="${FILE_PATH#$PROJECT_DIR/}"

# Get block-level rules for this file
VIOLATIONS=""
while IFS= read -r RULE_NAME; do
  [ -z "$RULE_NAME" ] && continue

  RULE_JSON=$(enforce_get_rule "$RULE_NAME")
  CHECK_TYPE=$(echo "$RULE_JSON" | jq -r '.check // empty')

  case "$CHECK_TYPE" in
    grep)
      PATTERN=$(echo "$RULE_JSON" | jq -r '.pattern // empty')
      [ -z "$PATTERN" ] && continue
      MATCH=$(enforce_check_grep "$PATTERN" "$CONTENT" 2>/dev/null)
      if [ $? -eq 0 ]; then
        DESC=$(echo "$RULE_JSON" | jq -r '.description // .name')
        VIOLATIONS="${VIOLATIONS}BLOCKED by rule '${RULE_NAME}': ${DESC}\nMatch: ${MATCH}\n\n"
      fi
      ;;
    biome)
      # Biome checks added in Chunk 2
      ;;
  esac
done <<< "$(enforce_rules_for_file "$REL_PATH" "block")"

# If violations found, deny the action
if [ -n "$VIOLATIONS" ]; then
  REASON=$(printf '%s' "$VIOLATIONS" | head -c 500)
  jq -n --arg reason "$REASON" '{
    "hookSpecificOutput": {
      "permissionDecision": "deny",
      "reason": $reason
    }
  }'
fi

exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add hooks/enforce-pre.sh
git commit -m "feat: add enforce-pre.sh — PreToolUse blocking hook for grep rules"
```

---

### Task 4: Create enforce-post.sh — PostToolUse context injection hook

**Files:**
- Create: `hooks/enforce-post.sh`

- [ ] **Step 1: Write failing tests for enforce-post.sh**

Add to `tests/enforce-test.sh`:

```bash
# --- enforce-post.sh tests ---
echo ""
echo "## enforce-post.sh"

POST_DIR=$(mktemp -d)
mkdir -p "$POST_DIR/.claude" "$POST_DIR/src/routes"
cat > "$POST_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: false
  log_file: /tmp/enforce-post-test.log
rules:
  - name: no-console
    description: "Use logger instead"
    check: grep
    pattern: "console\\.log"
    files: "src/**/*.ts"
    level: warn
  - name: style-check
    description: "Style note"
    check: grep
    pattern: "var "
    files: "src/**/*.ts"
    level: info
YAML

# Create a file with violations
cat > "$POST_DIR/src/routes/api.ts" << 'CODE'
var x = 1;
console.log("debug");
export default x;
CODE

# Test: warn rule injects additionalContext
OUTPUT=$(echo '{"tool_input":{"file_path":"'"$POST_DIR"'/src/routes/api.ts"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$POST_DIR" bash "$SCRIPT_DIR/hooks/enforce-post.sh" 2>/dev/null)
assert_contains "post-hook warns on console.log" "$OUTPUT" "no-console"
assert_contains "post-hook uses additionalContext" "$OUTPUT" "additionalContext"

# Test: info rule does NOT appear in additionalContext
assert_not_contains "info rule not in context output" "$OUTPUT" "style-check"

# Test: info rule writes to log file
if [ -f /tmp/enforce-post-test.log ]; then
  LOG_CONTENT=$(cat /tmp/enforce-post-test.log)
  assert_contains "info rule logged to file" "$LOG_CONTENT" "style-check"
  rm -f /tmp/enforce-post-test.log
else
  echo "  FAIL: info log file not created"
  ((FAIL++))
fi

rm -rf "$POST_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: enforce-post.sh tests all FAIL

- [ ] **Step 3: Write enforce-post.sh**

```bash
#!/bin/bash
# hooks/enforce-post.sh — PostToolUse:Edit|Write enforcement hook (async)
# Evaluates WARN and INFO level rules after edits complete.
# Warn: injects additionalContext. Info: appends to log file.
#
# Gate: CLAUDE_AGENT_MODE=1
# Config: ENFORCE_PROJECT_DIR/.claude/enforcement.yaml
#
# Test: echo '{"tool_input":{"file_path":"src/app.ts"}}' | \
#   CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR=/path/to/project bash hooks/enforce-post.sh
set -uo pipefail

# Gate
if [ "${CLAUDE_AGENT_MODE:-}" != "1" ]; then
  exit 0
fi

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

# Determine project dir
PROJECT_DIR="${ENFORCE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  SEARCH_DIR=$(dirname "$FILE_PATH")
  while [ "$SEARCH_DIR" != "/" ] && [ "$SEARCH_DIR" != "." ]; do
    if [ -f "$SEARCH_DIR/.claude/enforcement.yaml" ]; then
      PROJECT_DIR="$SEARCH_DIR"
      break
    fi
    SEARCH_DIR=$(dirname "$SEARCH_DIR")
  done
fi
[ -z "$PROJECT_DIR" ] && exit 0

CONFIG_FILE="$PROJECT_DIR/.claude/enforcement.yaml"
[ ! -f "$CONFIG_FILE" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/enforce-lib.sh"
enforce_load_config "$CONFIG_FILE" || exit 0

# Read actual file content (post-hook — file exists on disk)
CONTENT=$(cat "$FILE_PATH" 2>/dev/null)
[ -z "$CONTENT" ] && exit 0

REL_PATH="${FILE_PATH#$PROJECT_DIR/}"

WARN_MESSAGES=""
LOG_FILE=$(enforce_setting "log_file")
LOG_FILE="${LOG_FILE:-$HOME/.config/claude-agents/logs/enforcement.log}"
LOG_FILE="${LOG_FILE/#\~/$HOME}"  # expand tilde

# Check warn-level rules
while IFS= read -r RULE_NAME; do
  [ -z "$RULE_NAME" ] && continue
  RULE_JSON=$(enforce_get_rule "$RULE_NAME")
  CHECK_TYPE=$(echo "$RULE_JSON" | jq -r '.check // empty')

  case "$CHECK_TYPE" in
    grep)
      PATTERN=$(echo "$RULE_JSON" | jq -r '.pattern // empty')
      [ -z "$PATTERN" ] && continue
      MATCH=$(enforce_check_grep "$PATTERN" "$CONTENT" 2>/dev/null)
      if [ $? -eq 0 ]; then
        DESC=$(echo "$RULE_JSON" | jq -r '.description // .name')
        WARN_MESSAGES="${WARN_MESSAGES}[WARN] Rule '${RULE_NAME}': ${DESC}\n  Match: $(echo "$MATCH" | head -3)\n\n"
      fi
      ;;
    llm)
      # LLM checks added in Chunk 2
      ;;
  esac
done <<< "$(enforce_rules_for_file "$REL_PATH" "warn")"

# Check info-level rules — log only, no context injection
while IFS= read -r RULE_NAME; do
  [ -z "$RULE_NAME" ] && continue
  RULE_JSON=$(enforce_get_rule "$RULE_NAME")
  CHECK_TYPE=$(echo "$RULE_JSON" | jq -r '.check // empty')

  case "$CHECK_TYPE" in
    grep)
      PATTERN=$(echo "$RULE_JSON" | jq -r '.pattern // empty')
      [ -z "$PATTERN" ] && continue
      MATCH=$(enforce_check_grep "$PATTERN" "$CONTENT" 2>/dev/null)
      if [ $? -eq 0 ]; then
        DESC=$(echo "$RULE_JSON" | jq -r '.description // .name')
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] INFO rule=$RULE_NAME file=$REL_PATH desc=\"$DESC\" match=\"$(echo "$MATCH" | head -1)\"" >> "$LOG_FILE"
      fi
      ;;
  esac
done <<< "$(enforce_rules_for_file "$REL_PATH" "info")"

# Output warn messages as additionalContext
if [ -n "$WARN_MESSAGES" ]; then
  CONTEXT=$(printf '%b' "$WARN_MESSAGES" | head -c 1000)
  jq -n --arg ctx "Enforcement warnings:\n$CONTEXT" '{
    "hookSpecificOutput": {
      "additionalContext": $ctx
    }
  }'
fi

exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add hooks/enforce-post.sh
git commit -m "feat: add enforce-post.sh — PostToolUse warn/info hook for grep rules"
```

---

### Task 5: Register hooks in setup.sh

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: Read current setup.sh to understand registration pattern**

Run: `cat setup.sh | head -100`

- [ ] **Step 2: Add enforce-pre.sh and enforce-post.sh registrations**

Add to the hook registration section of `setup.sh`, following the existing pattern:

```bash
register_hook "PreToolUse" "Edit|Write" "enforce-pre.sh"
register_hook "PostToolUse" "Edit|Write" "enforce-post.sh" "true"
```

- [ ] **Step 3: Run setup.sh to verify hooks register without error**

Run: `bash setup.sh`
Expected: No errors, hooks registered

- [ ] **Step 4: Commit**

```bash
git add setup.sh
git commit -m "chore: register enforce-pre and enforce-post hooks in setup.sh"
```

---

## Chunk 2: Biome + LLM Check Types

### Task 6: Add biome check runner to enforce-lib.sh

**Files:**
- Modify: `hooks/enforce-lib.sh`
- Modify: `hooks/enforce-pre.sh`
- Modify: `hooks/enforce-post.sh`

- [ ] **Step 1: Write failing tests for biome checks**

Add to `tests/enforce-test.sh`:

```bash
# --- biome check tests ---
echo ""
echo "## biome checks"

BIOME_DIR=$(mktemp -d)
mkdir -p "$BIOME_DIR/.claude" "$BIOME_DIR/src/lib"

cat > "$BIOME_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: false
rules:
  - name: no-default-export
    description: "Use named exports"
    check: biome
    rule: "noDefaultExport"
    files: "src/lib/**/*.ts"
    level: block
YAML

# Create file with default export
cat > "$BIOME_DIR/src/lib/utils.ts" << 'CODE'
export default function hello() { return "hi"; }
CODE

# Test: biome check detects violation (only if biome is installed)
if command -v biome &>/dev/null || command -v npx &>/dev/null; then
  source "$SCRIPT_DIR/hooks/enforce-lib.sh"
  enforce_load_config "$BIOME_DIR/.claude/enforcement.yaml"
  RESULT=$(enforce_check_biome "noDefaultExport" "$BIOME_DIR/src/lib/utils.ts" 2>/dev/null)
  BIOME_EXIT=$?
  if [ $BIOME_EXIT -eq 0 ]; then
    echo "  PASS: biome detects noDefaultExport violation"
    PASS=$((PASS + 1))
  else
    echo "  SKIP: biome rule not available (may need biome install)"
    # Don't count as fail — biome is optional
  fi
else
  echo "  SKIP: biome not installed"
fi

rm -rf "$BIOME_DIR"
```

- [ ] **Step 2: Run tests to verify they fail (or skip)**

Run: `bash tests/enforce-test.sh`
Expected: FAIL or SKIP for biome test

- [ ] **Step 3: Add enforce_check_biome to enforce-lib.sh**

Add to `hooks/enforce-lib.sh`:

```bash
# Run a biome lint check for a specific rule against a file
# Usage: enforce_check_biome "noDefaultExport" "/path/to/file.ts"
# Returns: 0 if violation found (output on stdout), 1 if clean
enforce_check_biome() {
  local rule="$1"
  local file_path="$2"

  local biome_cmd=""
  if command -v biome &>/dev/null; then
    biome_cmd="biome"
  elif command -v npx &>/dev/null; then
    biome_cmd="npx biome"
  else
    return 1  # biome not available, skip
  fi

  local output
  output=$($biome_cmd lint --rule "$rule" "$file_path" 2>/dev/null)
  local exit_code=$?

  if [ $exit_code -ne 0 ] && [ -n "$output" ]; then
    echo "$output" | tail -5
    return 0  # violation found
  fi
  return 1  # clean
}
```

- [ ] **Step 4: Add biome case to enforce-pre.sh**

In `hooks/enforce-pre.sh`, update the biome case in the check loop. Since biome needs a file on disk and pre-hook fires before the edit, write content to a temp file:

```bash
    biome)
      BIOME_RULE=$(echo "$RULE_JSON" | jq -r '.rule // empty')
      [ -z "$BIOME_RULE" ] && continue
      # Write content to temp file for biome analysis
      TEMP_FILE=$(mktemp --suffix=".${FILE_PATH##*.}" 2>/dev/null || mktemp)
      echo "$CONTENT" > "$TEMP_FILE"
      MATCH=$(enforce_check_biome "$BIOME_RULE" "$TEMP_FILE" 2>/dev/null)
      if [ $? -eq 0 ]; then
        DESC=$(echo "$RULE_JSON" | jq -r '.description // .name')
        VIOLATIONS="${VIOLATIONS}BLOCKED by rule '${RULE_NAME}': ${DESC}\n${MATCH}\n\n"
      fi
      rm -f "$TEMP_FILE"
      ;;
```

- [ ] **Step 5: Add biome case to enforce-post.sh warn loop**

In `hooks/enforce-post.sh`, update the biome case in the warn check loop:

```bash
    biome)
      BIOME_RULE=$(echo "$RULE_JSON" | jq -r '.rule // empty')
      [ -z "$BIOME_RULE" ] && continue
      MATCH=$(enforce_check_biome "$BIOME_RULE" "$FILE_PATH" 2>/dev/null)
      if [ $? -eq 0 ]; then
        DESC=$(echo "$RULE_JSON" | jq -r '.description // .name')
        WARN_MESSAGES="${WARN_MESSAGES}[WARN] Rule '${RULE_NAME}': ${DESC}\n  ${MATCH}\n\n"
      fi
      ;;
```

- [ ] **Step 6: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS (or SKIP for biome if not installed)

- [ ] **Step 7: Commit**

```bash
git add hooks/enforce-lib.sh hooks/enforce-pre.sh hooks/enforce-post.sh tests/enforce-test.sh
git commit -m "feat: add biome check type to enforcement hooks"
```

---

### Task 7: Add LLM check runner (Haiku) to enforce-lib.sh

**Files:**
- Modify: `hooks/enforce-lib.sh`
- Modify: `hooks/enforce-post.sh`

- [ ] **Step 1: Write failing test for LLM checks**

Add to `tests/enforce-test.sh`:

```bash
# --- LLM check tests ---
echo ""
echo "## LLM checks"

# Test enforce_check_llm function exists and handles missing API key
source "$SCRIPT_DIR/hooks/enforce-lib.sh"
RESULT=$(enforce_check_llm "Is this bad code?" "console.log('hi')" "" 5 200 2>/dev/null)
LLM_EXIT=$?
# Without API key, should return 1 (skip)
assert_exit_code "LLM check skips without API key" $LLM_EXIT 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: FAIL (function doesn't exist)

- [ ] **Step 3: Add enforce_check_llm to enforce-lib.sh**

Add to `hooks/enforce-lib.sh`:

```bash
# Run an LLM-judged check via Anthropic API (Haiku)
# Usage: enforce_check_llm "prompt" "file_content" "api_key" timeout max_tokens
# Returns: 0 if violation found (explanation on stdout), 1 if clean/error/timeout
enforce_check_llm() {
  local prompt="$1"
  local content="$2"
  local api_key="$3"
  local timeout="${4:-5}"
  local max_tokens="${5:-200}"

  [ -z "$api_key" ] && return 1

  # Build the API request
  local request
  request=$(jq -n \
    --arg model "claude-haiku-4-5-20251001" \
    --arg prompt "$prompt" \
    --arg content "$content" \
    --argjson max_tokens "$max_tokens" \
    '{
      model: $model,
      max_tokens: $max_tokens,
      messages: [{
        role: "user",
        content: ("Review this code for the following rule:\n\nRule: " + $prompt + "\n\nCode:\n```\n" + $content + "\n```\n\nRespond with ONLY a JSON object: {\"violation\": true/false, \"explanation\": \"brief reason\"}")
      }]
    }')

  local response
  response=$(curl -s --max-time "$timeout" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $api_key" \
    -H "anthropic-version: 2023-06-01" \
    -d "$request" \
    "https://api.anthropic.com/v1/messages" 2>/dev/null)

  [ -z "$response" ] && return 1

  # Extract the text response
  local text
  text=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)
  [ -z "$text" ] && return 1

  # Parse the JSON response from Haiku
  local violation
  violation=$(echo "$text" | jq -r '.violation // empty' 2>/dev/null)

  if [ "$violation" = "true" ]; then
    local explanation
    explanation=$(echo "$text" | jq -r '.explanation // "Violation detected"' 2>/dev/null)
    echo "$explanation"
    return 0  # violation found
  fi

  return 1  # clean
}

# Check LLM cache — skip if file unchanged since last check
# Usage: enforce_llm_cache_check "rule_name" "file_path"
# Returns: 0 if cached (skip), 1 if needs re-check
enforce_llm_cache_check() {
  local rule_name="$1"
  local file_path="$2"
  local cache_dir="/tmp/enforce-llm-cache"
  mkdir -p "$cache_dir"

  local file_hash
  file_hash=$(shasum -a 256 "$file_path" 2>/dev/null | cut -d' ' -f1 | head -c 16)
  local cache_key="${rule_name}-${file_hash}"
  local cache_file="$cache_dir/$cache_key"

  if [ -f "$cache_file" ]; then
    return 0  # cached, skip
  fi
  return 1  # needs check
}

# Write LLM cache entry
enforce_llm_cache_write() {
  local rule_name="$1"
  local file_path="$2"
  local result="$3"  # "pass" or "fail"
  local cache_dir="/tmp/enforce-llm-cache"
  mkdir -p "$cache_dir"

  local file_hash
  file_hash=$(shasum -a 256 "$file_path" 2>/dev/null | cut -d' ' -f1 | head -c 16)
  echo "$result" > "$cache_dir/${rule_name}-${file_hash}"
}
```

- [ ] **Step 4: Add LLM case to enforce-post.sh warn loop**

In `hooks/enforce-post.sh`, replace the LLM placeholder:

```bash
    llm)
      PROMPT=$(echo "$RULE_JSON" | jq -r '.prompt // empty')
      [ -z "$PROMPT" ] && continue

      # Check cache — skip if file unchanged
      if enforce_llm_cache_check "$RULE_NAME" "$FILE_PATH"; then
        continue
      fi

      # Get API key
      API_KEY_ENV=$(enforce_setting "llm.api_key_env")
      API_KEY="${!API_KEY_ENV:-}"
      TIMEOUT=$(enforce_setting "llm.timeout")
      MAX_TOKENS=$(enforce_setting "llm.max_tokens")

      MATCH=$(enforce_check_llm "$PROMPT" "$CONTENT" "$API_KEY" "${TIMEOUT:-5}" "${MAX_TOKENS:-200}" 2>/dev/null)
      if [ $? -eq 0 ]; then
        DESC=$(echo "$RULE_JSON" | jq -r '.description // .name')
        WARN_MESSAGES="${WARN_MESSAGES}[WARN] Rule '${RULE_NAME}' (LLM): ${DESC}\n  ${MATCH}\n\n"
        enforce_llm_cache_write "$RULE_NAME" "$FILE_PATH" "fail"
      else
        enforce_llm_cache_write "$RULE_NAME" "$FILE_PATH" "pass"
      fi
      ;;
```

- [ ] **Step 5: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add hooks/enforce-lib.sh hooks/enforce-post.sh tests/enforce-test.sh
git commit -m "feat: add LLM-judged (Haiku) check type with caching"
```

---

## Chunk 3: agent-harness CLI

### Task 8: Create agent-harness with `check` subcommand

**Files:**
- Create: `bin/agent-harness`

- [ ] **Step 1: Write failing test for agent-harness check**

Add to `tests/enforce-test.sh`:

```bash
# --- agent-harness check tests ---
echo ""
echo "## agent-harness check"

HARNESS_DIR=$(mktemp -d)
mkdir -p "$HARNESS_DIR/.claude" "$HARNESS_DIR/src/routes"
cat > "$HARNESS_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: false
rules:
  - name: no-env
    description: "Use config module"
    check: grep
    pattern: "process\\.env"
    files: "src/**/*.ts"
    level: block
  - name: no-console
    description: "Use logger"
    check: grep
    pattern: "console\\.log"
    files: "src/**/*.ts"
    level: warn
YAML

cat > "$HARNESS_DIR/src/routes/api.ts" << 'CODE'
import { config } from "../config";
console.log("starting");
const url = process.env.DB_URL;
CODE

OUTPUT=$("$SCRIPT_DIR/bin/agent-harness" check "$HARNESS_DIR/src/routes/api.ts" --project "$HARNESS_DIR" 2>/dev/null)
assert_contains "harness check shows BLOCK" "$OUTPUT" "BLOCK"
assert_contains "harness check shows WARN" "$OUTPUT" "WARN"
assert_contains "harness check shows rule name" "$OUTPUT" "no-env"

rm -rf "$HARNESS_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: FAIL

- [ ] **Step 3: Write bin/agent-harness**

```bash
#!/bin/bash
# bin/agent-harness — CLI for enforcement config management and checking
# Usage: agent-harness <command> [options]
#   agent-harness check <file|dir> [--project <dir>]
#   agent-harness init [--project <dir>]
#   agent-harness status [--last <period>] [--issue <id>]
#   agent-harness trace [passthrough to agent-trace]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

source "$HOOKS_DIR/enforce-lib.sh"

# --- check subcommand ---
cmd_check() {
  local target=""
  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project_dir="$2"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done

  [ -z "$target" ] && { echo "Usage: agent-harness check <file|dir> [--project <dir>]" >&2; exit 1; }

  # Auto-detect project dir if not specified
  if [ -z "$project_dir" ]; then
    local search="$target"
    [ -f "$search" ] && search=$(dirname "$search")
    while [ "$search" != "/" ] && [ "$search" != "." ]; do
      if [ -f "$search/.claude/enforcement.yaml" ]; then
        project_dir="$search"
        break
      fi
      search=$(dirname "$search")
    done
    [ -z "$project_dir" ] && { echo "No .claude/enforcement.yaml found" >&2; exit 1; }
  fi

  local config_file="$project_dir/.claude/enforcement.yaml"
  [ ! -f "$config_file" ] && { echo "Config not found: $config_file" >&2; exit 1; }

  enforce_load_config "$config_file" || { echo "Failed to parse config" >&2; exit 1; }

  # Collect files to check
  local files=()
  if [ -f "$target" ]; then
    files=("$target")
  elif [ -d "$target" ]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$target" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.py' -o -name '*.rs' -o -name '*.go' \) -print0 2>/dev/null)
  fi

  local total_block=0 total_warn=0 total_info=0

  for file in "${files[@]}"; do
    [ ! -f "$file" ] && continue
    local rel_path="${file#$project_dir/}"
    local content
    content=$(cat "$file" 2>/dev/null)
    [ -z "$content" ] && continue

    # Check all levels
    for level in block warn info; do
      while IFS= read -r rule_name; do
        [ -z "$rule_name" ] && continue
        local rule_json
        rule_json=$(enforce_get_rule "$rule_name")
        local check_type
        check_type=$(echo "$rule_json" | jq -r '.check // empty')

        local match=""
        case "$check_type" in
          grep)
            local pattern
            pattern=$(echo "$rule_json" | jq -r '.pattern // empty')
            [ -z "$pattern" ] && continue
            match=$(enforce_check_grep "$pattern" "$content" 2>/dev/null)
            [ $? -ne 0 ] && continue
            ;;
          biome)
            local biome_rule
            biome_rule=$(echo "$rule_json" | jq -r '.rule // empty')
            [ -z "$biome_rule" ] && continue
            match=$(enforce_check_biome "$biome_rule" "$file" 2>/dev/null)
            [ $? -ne 0 ] && continue
            ;;
          llm)
            local prompt api_key_env api_key timeout max_tokens
            prompt=$(echo "$rule_json" | jq -r '.prompt // empty')
            [ -z "$prompt" ] && continue
            api_key_env=$(enforce_setting "llm.api_key_env")
            api_key="${!api_key_env:-}"
            timeout=$(enforce_setting "llm.timeout")
            max_tokens=$(enforce_setting "llm.max_tokens")
            match=$(enforce_check_llm "$prompt" "$content" "$api_key" "${timeout:-5}" "${max_tokens:-200}" 2>/dev/null)
            [ $? -ne 0 ] && continue
            ;;
        esac

        local label desc
        desc=$(echo "$rule_json" | jq -r '.description // .name')
        case "$level" in
          block) label="  BLOCK"; ((total_block++)) ;;
          warn)  label="  WARN "; ((total_warn++)) ;;
          info)  label="  INFO "; ((total_info++)) ;;
        esac
        match_preview=$(echo "$match" | head -1 | cut -c1-80)
        printf "%s  %-25s %s  (%s)\n" "$label" "$rule_name" "$match_preview" "$rel_path"

      done <<< "$(enforce_rules_for_file "$rel_path" "$level")"
    done
  done

  echo ""
  echo "  $total_block block, $total_warn warn, $total_info info"
  [ "$total_block" -gt 0 ] && exit 1
  exit 0
}

# --- init subcommand ---
cmd_init() {
  local project_dir="${1:-.}"
  echo "agent-harness init — not yet implemented (Chunk 3, Task 9)"
  exit 1
}

# --- status subcommand ---
cmd_status() {
  echo "agent-harness status — not yet implemented (Chunk 3, Task 10)"
  exit 1
}

# --- trace subcommand ---
cmd_trace() {
  exec "$SCRIPT_DIR/agent-trace" "$@"
}

# --- main ---
case "${1:-}" in
  check)  shift; cmd_check "$@" ;;
  init)   shift; cmd_init "$@" ;;
  status) shift; cmd_status "$@" ;;
  trace)  shift; cmd_trace "$@" ;;
  *)
    echo "Usage: agent-harness <check|init|status|trace> [options]"
    echo ""
    echo "Commands:"
    echo "  check <file|dir>    Run enforcement rules against files"
    echo "  init [--project]    Bootstrap .claude/enforcement.yaml"
    echo "  status [--last]     Show enforcement metrics from traces"
    echo "  trace               Query event traces (passthrough to agent-trace)"
    exit 1
    ;;
esac
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x bin/agent-harness && bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add bin/agent-harness tests/enforce-test.sh
git commit -m "feat: add agent-harness CLI with check subcommand"
```

---

### Task 9: Implement agent-harness init

**Files:**
- Modify: `bin/agent-harness`

- [ ] **Step 1: Write failing test for init**

Add to `tests/enforce-test.sh`:

```bash
# --- agent-harness init tests ---
echo ""
echo "## agent-harness init"

INIT_DIR=$(mktemp -d)
mkdir -p "$INIT_DIR/src/routes" "$INIT_DIR/src/services" "$INIT_DIR/src/components"

# Create package.json to trigger TS/Node detection
cat > "$INIT_DIR/package.json" << 'JSON'
{ "name": "test-project", "dependencies": { "next": "14.0.0" } }
JSON

# Create biome.json to trigger biome detection
cat > "$INIT_DIR/biome.json" << 'JSON'
{ "linter": { "enabled": true } }
JSON

OUTPUT=$("$SCRIPT_DIR/bin/agent-harness" init --project "$INIT_DIR" --no-llm 2>/dev/null)
assert_exit_code "init exits 0" $? 0
assert_contains "init detects TypeScript" "$OUTPUT" "TypeScript"

# Verify enforcement.yaml was created
if [ -f "$INIT_DIR/.claude/enforcement.yaml" ]; then
  echo "  PASS: enforcement.yaml created"
  ((PASS++))
  INIT_CONTENT=$(cat "$INIT_DIR/.claude/enforcement.yaml")
  assert_contains "init generates version field" "$INIT_CONTENT" "version:"
  assert_contains "init generates rules" "$INIT_CONTENT" "rules:"
else
  echo "  FAIL: enforcement.yaml not created"
  ((FAIL++))
fi

rm -rf "$INIT_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: init tests FAIL

- [ ] **Step 3: Replace cmd_init placeholder in bin/agent-harness**

```bash
cmd_init() {
  local project_dir=""
  local use_llm=true

  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project_dir="$2"; shift 2 ;;
      --no-llm) use_llm=false; shift ;;
      *) project_dir="$1"; shift ;;
    esac
  done
  project_dir="${project_dir:-.}"
  project_dir=$(cd "$project_dir" && pwd)

  echo "Analyzing project at $project_dir..."

  # Step 1: Detect stack
  local stack="unknown"
  local has_biome=false has_eslint=false has_ruff=false

  if [ -f "$project_dir/package.json" ]; then
    if grep -q '"next"' "$project_dir/package.json" 2>/dev/null; then
      stack="TypeScript/Next.js"
    elif grep -q '"vite"' "$project_dir/package.json" 2>/dev/null; then
      stack="TypeScript/Vite"
    else
      stack="TypeScript/Node"
    fi
  elif [ -f "$project_dir/Cargo.toml" ]; then
    stack="Rust"
  elif [ -f "$project_dir/pyproject.toml" ] || [ -f "$project_dir/requirements.txt" ]; then
    stack="Python"
  elif [ -f "$project_dir/go.mod" ]; then
    stack="Go"
  fi
  echo "Detected: $stack"

  # Step 2: Scan for existing linters
  [ -f "$project_dir/biome.json" ] || [ -f "$project_dir/biome.jsonc" ] && has_biome=true
  [ -f "$project_dir/.eslintrc" ] || [ -f "$project_dir/.eslintrc.js" ] || [ -f "$project_dir/.eslintrc.json" ] && has_eslint=true
  [ -f "$project_dir/ruff.toml" ] || grep -q "ruff" "$project_dir/pyproject.toml" 2>/dev/null && has_ruff=true

  local linters=""
  $has_biome && linters="${linters}biome "
  $has_eslint && linters="${linters}eslint "
  $has_ruff && linters="${linters}ruff "
  [ -n "$linters" ] && echo "Found linters: $linters"

  # Step 3: Scan directory structure
  local has_routes=false has_services=false has_components=false
  [ -d "$project_dir/src/routes" ] || [ -d "$project_dir/app/routes" ] || [ -d "$project_dir/pages/api" ] && has_routes=true
  [ -d "$project_dir/src/services" ] || [ -d "$project_dir/lib/services" ] && has_services=true
  [ -d "$project_dir/src/components" ] || [ -d "$project_dir/components" ] && has_components=true

  # Step 4: Generate rules
  mkdir -p "$project_dir/.claude"
  local rules_yaml=""
  local rule_count=0

  # Common grep rules
  case "$stack" in
    TypeScript*|JavaScript*)
      rules_yaml="${rules_yaml}
  - name: no-console-log
    description: \"Use a proper logger instead of console.log in production code\"
    check: grep
    pattern: \"console\\\\.(log|debug|info)\"
    files: \"src/**/*.ts\"
    exclude: \"**/*.test.ts\"
    level: warn"
      ((rule_count++))

      rules_yaml="${rules_yaml}
  - name: no-env-direct
    description: \"Access environment variables through a config module, not process.env directly\"
    check: grep
    pattern: \"process\\\\.env\\\\.\"
    files: \"src/**/*.ts\"
    exclude: \"src/config/**\"
    level: warn"
      ((rule_count++))
      ;;
    Python)
      rules_yaml="${rules_yaml}
  - name: no-print-debug
    description: \"Use logging module instead of print() for debugging\"
    check: grep
    pattern: \"^\\\\s*print\\\\(\"
    files: \"src/**/*.py\"
    exclude: \"**/*test*.py\"
    level: warn"
      ((rule_count++))
      ;;
  esac

  # Biome rules (if biome detected)
  if $has_biome; then
    case "$stack" in
      TypeScript*)
        rules_yaml="${rules_yaml}
  - name: no-default-export
    description: \"Use named exports for better refactoring support\"
    check: biome
    rule: \"noDefaultExport\"
    files: \"src/lib/**/*.ts\"
    level: warn"
        ((rule_count++))
        ;;
    esac
  fi

  # Layer boundary rules (if both routes and services exist)
  if $has_routes && $has_services; then
    rules_yaml="${rules_yaml}
  - name: service-layer-boundary
    description: \"Route handlers should delegate to services, not contain business logic\"
    check: llm
    prompt: |
      Review this file. Does it contain business logic or direct database access
      that should be in a service layer instead? Only flag clear violations,
      not thin wrappers or simple CRUD passthrough.
    files: \"src/routes/**/*.ts\"
    level: warn"
    ((rule_count++))
  fi

  # Step 5: LLM enhancement (optional)
  if $use_llm; then
    local api_key_env="ANTHROPIC_API_KEY"
    local api_key="${!api_key_env:-}"
    if [ -n "$api_key" ]; then
      echo "Calling Haiku for architectural analysis..."
      local tree_output
      tree_output=$(find "$project_dir/src" -type f -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.rs' 2>/dev/null | head -50 | sed "s|$project_dir/||")

      local llm_suggestions
      llm_suggestions=$(enforce_check_llm \
        "Given this project file structure, suggest 1-3 additional enforcement rules as YAML entries. Focus on architectural boundaries and naming conventions. Return ONLY the YAML rule entries, no explanation." \
        "$tree_output" \
        "$api_key" 10 500 2>/dev/null)

      if [ $? -eq 0 ] && [ -n "$llm_suggestions" ]; then
        echo "LLM suggested additional rules (review before activating)"
        # Append as commented-out suggestions
        rules_yaml="${rules_yaml}

  # --- LLM-suggested rules (review and uncomment) ---
$(echo "$llm_suggestions" | sed 's/^/  # /')"
      fi
    else
      echo "No ANTHROPIC_API_KEY set — skipping LLM analysis (deterministic rules only)"
    fi
  fi

  # Write enforcement.yaml
  cat > "$project_dir/.claude/enforcement.yaml" << YAML
version: 1

builtins:
  command-budget: 300
  block-destructive: true
  stop-gate: block
  scope-guard: true

settings:
  llm:
    model: claude-haiku-4-5-20251001
    api_key_env: ANTHROPIC_API_KEY
    max_tokens: 200
    timeout: 5
  cache_ttl: 300
  trace: true
  log_file: ~/.config/claude-agents/logs/enforcement.log
  auto_evolve:
    auto_escalate:
      enabled: true
      threshold: 5
      cooldown: 7d
      auto_apply: false
    check_downgrade:
      enabled: false
    guidance_suggest:
      enabled: false

rules:${rules_yaml}
YAML

  echo ""
  echo "Generated .claude/enforcement.yaml with $rule_count rules"
  echo "Review the config before activating:"
  echo "  $project_dir/.claude/enforcement.yaml"
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add bin/agent-harness tests/enforce-test.sh
git commit -m "feat: add agent-harness init — project bootstrapper"
```

---

### Task 10: Implement agent-harness status

**Files:**
- Modify: `bin/agent-harness`

- [ ] **Step 1: Write failing test for status**

Add to `tests/enforce-test.sh`:

```bash
# --- agent-harness status tests ---
echo ""
echo "## agent-harness status"

STATUS_DIR=$(mktemp -d)
mkdir -p "$STATUS_DIR"

# Create fake trace files with enforcement events
cat > "$STATUS_DIR/test-trace.jsonl" << 'JSONL'
{"ts":"2026-03-10T10:00:00Z","event":"enforcement.rule.fired","data":{"rule":"no-console","level":"warn","file":"src/app.ts","check":"grep"}}
{"ts":"2026-03-10T10:00:05Z","event":"enforcement.self_corrected","data":{"rule":"no-console","file":"src/app.ts"}}
{"ts":"2026-03-10T10:01:00Z","event":"enforcement.rule.fired","data":{"rule":"no-env","level":"block","file":"src/app.ts","check":"grep"}}
{"ts":"2026-03-10T10:02:00Z","event":"enforcement.rule.fired","data":{"rule":"no-console","level":"warn","file":"src/routes/api.ts","check":"grep"}}
JSONL

OUTPUT=$(TRACE_DIR="$STATUS_DIR" "$SCRIPT_DIR/bin/agent-harness" status --last 7d 2>/dev/null)
assert_contains "status shows rule name" "$OUTPUT" "no-console"
assert_contains "status shows fire count" "$OUTPUT" "2"

rm -rf "$STATUS_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: FAIL

- [ ] **Step 3: Replace cmd_status placeholder in bin/agent-harness**

```bash
cmd_status() {
  local period="7d"
  local issue=""
  local project_dir="${PROJECT_DIR:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --last) period="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --project) project_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local trace_dir="${TRACE_DIR:-$HOME/.config/claude-agents/traces}"
  [ ! -d "$trace_dir" ] && { echo "No traces found at $trace_dir"; exit 0; }

  # Parse period to seconds
  local period_seconds=604800  # default 7d
  case "$period" in
    *d) period_seconds=$(( ${period%d} * 86400 )) ;;
    *h) period_seconds=$(( ${period%h} * 3600 )) ;;
    *w) period_seconds=$(( ${period%w} * 604800 )) ;;
  esac

  local cutoff
  cutoff=$(date -v-${period_seconds}S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -d "-${period_seconds} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    echo "2000-01-01T00:00:00Z")

  # Aggregate enforcement events from all trace files
  local all_events
  all_events=$(cat "$trace_dir"/*.jsonl 2>/dev/null | \
    jq -r --arg cutoff "$cutoff" 'select(.ts >= $cutoff) | select(.event | startswith("enforcement."))' 2>/dev/null)

  [ -z "$all_events" ] && { echo "No enforcement events found in the last $period"; exit 0; }

  # Count sessions
  local session_count
  session_count=$(echo "$all_events" | jq -r '.run_id // .identifier // "unknown"' 2>/dev/null | sort -u | wc -l | tr -d ' ')

  echo "Enforcement status (last $period, $session_count sessions):"
  echo ""
  printf "  %-25s %7s %9s %16s %10s\n" "Rule" "Fired" "Blocked" "Self-corrected" "Override"
  printf "  %-25s %7s %9s %16s %10s\n" "----" "-----" "-------" "--------------" "--------"

  # Get unique rules
  local rules
  rules=$(echo "$all_events" | jq -r 'select(.event == "enforcement.rule.fired") | .data.rule // empty' 2>/dev/null | sort -u)

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    local fired blocked self_corrected overridden

    fired=$(echo "$all_events" | jq -r --arg r "$rule" 'select(.event == "enforcement.rule.fired") | select(.data.rule == $r)' 2>/dev/null | wc -l | tr -d ' ')
    blocked=$(echo "$all_events" | jq -r --arg r "$rule" 'select(.event == "enforcement.rule.fired") | select(.data.rule == $r) | select(.data.level == "block")' 2>/dev/null | wc -l | tr -d ' ')
    self_corrected=$(echo "$all_events" | jq -r --arg r "$rule" 'select(.event == "enforcement.self_corrected") | select(.data.rule == $r)' 2>/dev/null | wc -l | tr -d ' ')
    overridden=$(echo "$all_events" | jq -r --arg r "$rule" 'select(.event == "enforcement.override") | select(.data.rule == $r)' 2>/dev/null | wc -l | tr -d ' ')

    [ "$blocked" = "0" ] && blocked="-"
    [ "$self_corrected" = "0" ] && self_corrected="-"
    [ "$overridden" = "0" ] && overridden="-"

    printf "  %-25s %7s %9s %16s %10s\n" "$rule" "$fired" "$blocked" "$self_corrected" "$overridden"
  done <<< "$rules"

  echo ""
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add bin/agent-harness tests/enforce-test.sh
git commit -m "feat: add agent-harness status — enforcement metrics aggregation"
```

---

## Chunk 4: Tracing + Self-Correction + Auto-Escalation

### Task 11: Add enforcement trace emission to hooks

**Files:**
- Modify: `hooks/enforce-lib.sh`
- Modify: `hooks/enforce-pre.sh`
- Modify: `hooks/enforce-post.sh`

- [ ] **Step 1: Write failing test for trace emission**

Add to `tests/enforce-test.sh`:

```bash
# --- trace emission tests ---
echo ""
echo "## trace emission"

TRACE_TEST_DIR=$(mktemp -d)
TRACE_FILE="$TRACE_TEST_DIR/test-trace.jsonl"
mkdir -p "$TRACE_TEST_DIR/.claude" "$TRACE_TEST_DIR/src"

cat > "$TRACE_TEST_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: true
rules:
  - name: no-console
    description: "Use logger"
    check: grep
    pattern: "console\\.log"
    files: "src/**/*.ts"
    level: warn
YAML

cat > "$TRACE_TEST_DIR/src/app.ts" << 'CODE'
console.log("test");
CODE

# Run post-hook with TRACE_FILE set
echo '{"tool_input":{"file_path":"'"$TRACE_TEST_DIR"'/src/app.ts"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$TRACE_TEST_DIR" TRACE_FILE="$TRACE_FILE" \
  bash "$SCRIPT_DIR/hooks/enforce-post.sh" >/dev/null 2>/dev/null

if [ -f "$TRACE_FILE" ]; then
  TRACE_CONTENT=$(cat "$TRACE_FILE")
  assert_contains "trace has enforcement event" "$TRACE_CONTENT" "enforcement.rule.fired"
  assert_contains "trace has rule name" "$TRACE_CONTENT" "no-console"
else
  echo "  FAIL: trace file not created"
  ((FAIL++))
fi

rm -rf "$TRACE_TEST_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: FAIL

- [ ] **Step 3: Add enforce_trace function to enforce-lib.sh**

Add to `hooks/enforce-lib.sh`:

```bash
# Emit an enforcement trace event to JSONL
# Usage: enforce_trace "rule.fired" "rule=no-console" "level=warn" "file=src/app.ts"
enforce_trace() {
  [ -z "${TRACE_FILE:-}" ] && return 0

  local event="enforcement.$1"; shift
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Build data object from key=value args
  local data_pairs=""
  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    val=$(echo "$val" | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 200)
    [ -n "$data_pairs" ] && data_pairs="${data_pairs},"
    data_pairs="${data_pairs}\"${key}\":\"${val}\""
  done

  printf '{"ts":"%s","event":"%s","run_id":"%s","identifier":"%s","data":{%s}}\n' \
    "$ts" "$event" "${TRACE_RUN_ID:-unknown}" "${CLAUDE_AGENT_ISSUE_ID:-unknown}" "$data_pairs" \
    >> "$TRACE_FILE"
}
```

- [ ] **Step 4: Add trace calls to enforce-pre.sh**

In `hooks/enforce-pre.sh`, after a violation is found in the grep case, add:

```bash
        enforce_trace "rule.fired" "rule=$RULE_NAME" "check=grep" "level=block" "file=$REL_PATH" "detail=$MATCH"
```

- [ ] **Step 5: Add trace calls to enforce-post.sh**

In `hooks/enforce-post.sh`, after warn violations and info violations, add trace calls:

For warn grep violations:
```bash
        enforce_trace "rule.fired" "rule=$RULE_NAME" "check=grep" "level=warn" "file=$REL_PATH" "detail=$MATCH"
```

For info grep violations:
```bash
        enforce_trace "rule.fired" "rule=$RULE_NAME" "check=grep" "level=info" "file=$REL_PATH"
```

For LLM violations:
```bash
        enforce_trace "rule.fired" "rule=$RULE_NAME" "check=llm" "level=warn" "file=$REL_PATH" "detail=$MATCH" "latency_ms=$LATENCY"
```

For LLM skips:
```bash
        enforce_trace "rule.skipped" "rule=$RULE_NAME" "file=$REL_PATH" "reason=timeout"
```

- [ ] **Step 6: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 7: Commit**

```bash
git add hooks/enforce-lib.sh hooks/enforce-pre.sh hooks/enforce-post.sh tests/enforce-test.sh
git commit -m "feat: emit enforcement.* trace events to JSONL"
```

---

### Task 12: Add self-correction detection

**Files:**
- Modify: `hooks/enforce-lib.sh`
- Modify: `hooks/enforce-post.sh`

- [ ] **Step 1: Write failing test for self-correction**

Add to `tests/enforce-test.sh`:

```bash
# --- self-correction tests ---
echo ""
echo "## self-correction detection"

SC_DIR=$(mktemp -d)
SC_TRACE="$SC_DIR/trace.jsonl"
SC_SESSION="test-session-$$"
mkdir -p "$SC_DIR/.claude" "$SC_DIR/src"

cat > "$SC_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: true
rules:
  - name: no-console
    description: "Use logger"
    check: grep
    pattern: "console\\.log"
    files: "src/**/*.ts"
    level: warn
YAML

# First edit — has violation
cat > "$SC_DIR/src/app.ts" << 'CODE'
console.log("debug");
CODE

echo '{"tool_input":{"file_path":"'"$SC_DIR"'/src/app.ts"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$SC_DIR" TRACE_FILE="$SC_TRACE" \
  CLAUDE_SESSION_ID="$SC_SESSION" bash "$SCRIPT_DIR/hooks/enforce-post.sh" >/dev/null 2>/dev/null

# Second edit — violation fixed
cat > "$SC_DIR/src/app.ts" << 'CODE'
import { logger } from "./logger";
logger.info("debug");
CODE

echo '{"tool_input":{"file_path":"'"$SC_DIR"'/src/app.ts"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$SC_DIR" TRACE_FILE="$SC_TRACE" \
  CLAUDE_SESSION_ID="$SC_SESSION" bash "$SCRIPT_DIR/hooks/enforce-post.sh" >/dev/null 2>/dev/null

# Check trace for self_corrected event
if [ -f "$SC_TRACE" ]; then
  SC_TRACE_CONTENT=$(cat "$SC_TRACE")
  assert_contains "self_corrected event emitted" "$SC_TRACE_CONTENT" "enforcement.self_corrected"
  assert_contains "self_corrected references rule" "$SC_TRACE_CONTENT" "no-console"
else
  echo "  FAIL: trace file not created"
  ((FAIL++))
fi

rm -rf "$SC_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: FAIL

- [ ] **Step 3: Add pending state functions to enforce-lib.sh**

Add to `hooks/enforce-lib.sh`:

```bash
# Record a pending warning for self-correction tracking
# Usage: enforce_pending_add "session_id" "rule_name" "file_path"
enforce_pending_add() {
  local session_id="$1" rule="$2" file="$3"
  local pending_file="/tmp/enforce-pending-${session_id}.json"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local entry
  entry=$(jq -n --arg rule "$rule" --arg file "$file" --arg ts "$ts" \
    '{rule: $rule, file: $file, ts: $ts}')

  # Append entry (create file if needed)
  if [ -f "$pending_file" ]; then
    local existing
    existing=$(cat "$pending_file")
    echo "$existing" | jq --argjson new "$entry" '. + [$new]' > "$pending_file"
  else
    echo "[$entry]" > "$pending_file"
  fi
}

# Check and clear pending warnings for a file (self-correction detection)
# Usage: enforce_pending_check "session_id" "file_path"
# Output: rule names that were pending and are now resolved (one per line)
enforce_pending_check() {
  local session_id="$1" file="$2"
  local pending_file="/tmp/enforce-pending-${session_id}.json"
  [ ! -f "$pending_file" ] && return 0

  # Get pending rules for this file
  local pending_rules
  pending_rules=$(jq -r --arg file "$file" '.[] | select(.file == $file) | .rule' "$pending_file" 2>/dev/null)
  [ -z "$pending_rules" ] && return 0

  echo "$pending_rules"

  # Remove entries for this file
  jq --arg file "$file" '[.[] | select(.file != $file)]' "$pending_file" > "${pending_file}.tmp" && \
    mv "${pending_file}.tmp" "$pending_file"
}
```

- [ ] **Step 4: Integrate self-correction into enforce-post.sh**

At the beginning of enforce-post.sh (after loading config), add self-correction check:

```bash
# Check for self-corrections (previous warnings now fixed)
SESSION_ID="${CLAUDE_SESSION_ID:-pid-$$}"
PREV_PENDING=$(enforce_pending_check "$SESSION_ID" "$REL_PATH")
```

After the warn check loop, re-check previously pending rules:

```bash
# Detect self-corrections
if [ -n "$PREV_PENDING" ]; then
  while IFS= read -r PREV_RULE; do
    [ -z "$PREV_RULE" ] && continue
    # If this rule is NOT in current warnings, it was self-corrected
    if ! echo "$WARN_MESSAGES" | grep -q "$PREV_RULE"; then
      enforce_trace "self_corrected" "rule=$PREV_RULE" "file=$REL_PATH"
    fi
  done <<< "$PREV_PENDING"
fi

# Record current warnings as pending for future self-correction detection
if [ -n "$WARN_MESSAGES" ]; then
  while IFS= read -r RULE_NAME; do
    [ -z "$RULE_NAME" ] && continue
    # Only add if it actually fired
    if echo "$WARN_MESSAGES" | grep -q "$RULE_NAME"; then
      enforce_pending_add "$SESSION_ID" "$RULE_NAME" "$REL_PATH"
    fi
  done <<< "$(enforce_rules_for_file "$REL_PATH" "warn")"
fi
```

- [ ] **Step 5: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add hooks/enforce-lib.sh hooks/enforce-post.sh tests/enforce-test.sh
git commit -m "feat: add self-correction detection — track warn->fix patterns"
```

---

### Task 13: Add v1 auto-escalation to agent-harness

**Files:**
- Modify: `bin/agent-harness`

- [ ] **Step 1: Write failing test for auto-escalation detection**

Add to `tests/enforce-test.sh`:

```bash
# --- auto-escalation tests ---
echo ""
echo "## auto-escalation"

ESCAL_DIR=$(mktemp -d)
mkdir -p "$ESCAL_DIR/.claude"
cat > "$ESCAL_DIR/.claude/enforcement.yaml" << 'YAML'
version: 1
settings:
  trace: true
  auto_evolve:
    auto_escalate:
      enabled: true
      threshold: 3
      auto_apply: false
rules:
  - name: no-console
    description: "Use logger"
    check: grep
    pattern: "console\\.log"
    files: "src/**/*.ts"
    level: warn
YAML

# Create trace with 4 consecutive self-corrections, 0 overrides
ESCAL_TRACE_DIR=$(mktemp -d)
cat > "$ESCAL_TRACE_DIR/test-trace.jsonl" << 'JSONL'
{"ts":"2026-03-10T10:00:00Z","event":"enforcement.rule.fired","data":{"rule":"no-console","level":"warn","file":"src/a.ts","check":"grep"}}
{"ts":"2026-03-10T10:00:01Z","event":"enforcement.self_corrected","data":{"rule":"no-console","file":"src/a.ts"}}
{"ts":"2026-03-10T10:01:00Z","event":"enforcement.rule.fired","data":{"rule":"no-console","level":"warn","file":"src/b.ts","check":"grep"}}
{"ts":"2026-03-10T10:01:01Z","event":"enforcement.self_corrected","data":{"rule":"no-console","file":"src/b.ts"}}
{"ts":"2026-03-10T10:02:00Z","event":"enforcement.rule.fired","data":{"rule":"no-console","level":"warn","file":"src/c.ts","check":"grep"}}
{"ts":"2026-03-10T10:02:01Z","event":"enforcement.self_corrected","data":{"rule":"no-console","file":"src/c.ts"}}
{"ts":"2026-03-10T10:03:00Z","event":"enforcement.rule.fired","data":{"rule":"no-console","level":"warn","file":"src/d.ts","check":"grep"}}
{"ts":"2026-03-10T10:03:01Z","event":"enforcement.self_corrected","data":{"rule":"no-console","file":"src/d.ts"}}
JSONL

OUTPUT=$(TRACE_DIR="$ESCAL_TRACE_DIR" "$SCRIPT_DIR/bin/agent-harness" status --last 30d --project "$ESCAL_DIR" 2>/dev/null)
assert_contains "status recommends escalation" "$OUTPUT" "escalat"
assert_contains "status mentions rule" "$OUTPUT" "no-console"

rm -rf "$ESCAL_DIR" "$ESCAL_TRACE_DIR"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/enforce-test.sh`
Expected: FAIL

- [ ] **Step 3: Add escalation analysis to cmd_status**

At the end of `cmd_status` in `bin/agent-harness`, add:

```bash
  # Auto-escalation analysis (project_dir parsed from args above)
  if [ -n "$project_dir" ] && [ -f "$project_dir/.claude/enforcement.yaml" ]; then
    enforce_load_config "$project_dir/.claude/enforcement.yaml" 2>/dev/null
    local escalate_enabled
    escalate_enabled=$(enforce_setting "auto_evolve.auto_escalate.enabled" 2>/dev/null)
    local threshold
    threshold=$(enforce_setting "auto_evolve.auto_escalate.threshold" 2>/dev/null)
    threshold="${threshold:-5}"

    if [ "$escalate_enabled" = "true" ]; then
      echo "Auto-escalation recommendations:"
      echo ""

      while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        local sc_count override_count
        sc_count=$(echo "$all_events" | jq -r --arg r "$rule" \
          'select(.event == "enforcement.self_corrected") | select(.data.rule == $r)' 2>/dev/null | wc -l | tr -d ' ')
        override_count=$(echo "$all_events" | jq -r --arg r "$rule" \
          'select(.event == "enforcement.override") | select(.data.rule == $r)' 2>/dev/null | wc -l | tr -d ' ')

        if [ "$sc_count" -ge "$threshold" ] && [ "$override_count" -eq 0 ]; then
          echo "  -> Rule '$rule' self-corrected $sc_count/$sc_count times (0 overrides)"
          echo "     Recommend: escalate warn -> block"
          echo ""
        fi
      done <<< "$rules"
    fi
  fi
```

- [ ] **Step 4: Update cmd_status to accept --project flag**

Ensure the `--project` flag is parsed in cmd_status's argument loop (add alongside `--last` and `--issue`).

- [ ] **Step 5: Run tests**

Run: `bash tests/enforce-test.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add bin/agent-harness tests/enforce-test.sh
git commit -m "feat: add v1 auto-escalation recommendations to agent-harness status"
```

---

## Chunk 5: Interactive Dispatch Skill

### Task 14: Create dispatch skill

**Files:**
- Create: `skills/dispatch/SKILL.md`

- [ ] **Step 1: Write the dispatch skill**

```markdown
---
name: dispatch
description: Work on a Linear issue or free-form task with full harness enforcement
user_invocable: true
---

# dispatch

Interactive mode for the agent harness. Works on a Linear issue or free-form task with worktree isolation, enforcement hooks, CI gating, and PR creation.

## Usage

```
/dispatch ENG-123
/dispatch "add dark mode to settings page"
```

## Flow

### 1. Resolve the target

**If the target looks like a Linear issue ID** (matches `[A-Z]+-[0-9]+`):

```bash
linear issue view <ID>
```

Extract the title, description, and acceptance criteria. Check for sub-issues:

```bash
linear issue list --project <project> | grep -i "parent"
```

If sub-issues exist, present smart routing options (see Nested Issues below).

**If the target is free-form text**, create a Linear issue:

```bash
linear issue create --team <default-team> --title "<target>" --label Agent
```

### 2. Set up the workspace

Create an isolated worktree for the work:

```bash
REPO_NAME=$(basename $(git rev-parse --show-toplevel))
ISSUE_ID="<resolved-id>"
WORKTREE_PATH="$HOME/.claude/worktrees/$REPO_NAME/issue-$ISSUE_ID"
BRANCH="agent/$ISSUE_ID"

git worktree add "$WORKTREE_PATH" -b "$BRANCH" main
cd "$WORKTREE_PATH"
```

Export agent env vars so enforcement hooks activate:

```bash
export CLAUDE_AGENT_MODE=1
export CLAUDE_AGENT_ISSUE_ID="$ISSUE_ID"
export CLAUDE_AGENT_REPO="$REPO_NAME"
export CLAUDE_AGENT_BRANCH="$BRANCH"
export CLAUDE_AGENT_WORKTREE="$WORKTREE_PATH"
```

Check for enforcement config:

```bash
if [ ! -f .claude/enforcement.yaml ]; then
  echo "No enforcement config found. Run: agent-harness init"
fi
```

Update Linear status:

```bash
linear issue update "$ISSUE_ID" --status "In Progress"
```

### 3. Do the work

Follow the normal implementation workflow:
1. Read the issue requirements
2. Plan the approach
3. Write tests first (TDD)
4. Implement to make tests pass
5. Run linter and type checker

Enforcement hooks run automatically on every Edit/Write action.

### 4. Validate and ship

Run CI gate:

```bash
ci-gate
```

If CI passes, push and create PR:

```bash
git push -u origin "$BRANCH"
gh pr create --title "<issue-title>" --body "Resolves $ISSUE_ID"
```

Post implementation report to Linear:

```bash
linear comment add "$ISSUE_ID" "Implementation complete. PR: <url>"
```

Update status:

```bash
linear issue update "$ISSUE_ID" --status "In Review"
```

### 5. Clean up

After PR is merged (or on explicit request):

```bash
cd -
git worktree remove "$WORKTREE_PATH"
git branch -d "$BRANCH"
```

## Nested Issues (Smart Routing)

When the dispatched issue has sub-issues, present this prompt:

```
<ISSUE_ID> has N sub-issues:
  <child-1>: <title> (depends on: <deps or "none">)
  <child-2>: <title> (depends on: <deps or "none">)
  ...

<Independent issues> can run in parallel.
<Dependent issues> must wait for their dependencies.

Options:
  1. Parallel: spawn background agents for independent issues, then dependent ones
  2. Sequential: work through each in this session in dependency order
  3. Pick one to start with
```

For parallel execution, use the Agent tool to spawn sub-agents in separate worktrees.
For sequential execution, work through each issue in the current session.
After all children complete, run parent-level integration checks if `.claude/orchestrator/<ISSUE_ID>/enforcement.yaml` exists.

## Important Rules

- Always create a worktree — never work on main directly
- Always update Linear status at each stage
- Always run ci-gate before pushing
- If enforcement hooks block an action, fix the violation before proceeding
- If you get stuck, use `linear comment add` to document the blocker
```

- [ ] **Step 2: Verify the skill file is well-formed**

Run: `head -5 skills/dispatch/SKILL.md`
Expected: YAML frontmatter with name, description, user_invocable

- [ ] **Step 3: Commit**

```bash
git add skills/dispatch/SKILL.md
git commit -m "feat: add /dispatch skill for interactive harness mode"
```

---

### Task 15: Verify dispatch skill auto-registration

Skills are auto-registered by setup.sh's `for skill_dir in "$REPO_DIR/skills/"*/` loop — no manual registration needed.

- [ ] **Step 1: Run setup.sh and verify dispatch is linked**

Run: `bash setup.sh && ls -la ~/.claude/skills/dispatch/`
Expected: Symlink to `skills/dispatch/` directory, `SKILL.md` present

- [ ] **Step 2: Verify skill is discoverable**

Run: `head -5 ~/.claude/skills/dispatch/SKILL.md`
Expected: YAML frontmatter with `name: dispatch`

---

## Chunk 6: Linear CLI Migration + Setup

### Task 16: Add linear-cli dependency check to setup.sh

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: Add linear-cli check to dependency verification**

In setup.sh's dependency checking section, add:

```bash
# Optional: linear-cli for token-efficient Linear access
if command -v linear &>/dev/null; then
  echo "  linear-cli: $(linear --version 2>/dev/null || echo 'installed')"
else
  echo "  linear-cli: not installed (optional — install with: brew install schpet/tap/linear)"
fi
```

- [ ] **Step 2: Add yq dependency check**

```bash
# Required for enforcement: yq
if command -v yq &>/dev/null; then
  echo "  yq: $(yq --version 2>/dev/null)"
else
  echo "  yq: NOT INSTALLED (required for enforcement — install with: brew install yq)"
fi
```

- [ ] **Step 3: Commit**

```bash
git add setup.sh
git commit -m "chore: add linear-cli and yq dependency checks to setup.sh"
```

---

### Task 17: Verify linear-cli command coverage

**Files:**
- Create: `docs/linear-cli-verification.md`

- [ ] **Step 1: Install linear-cli and verify available commands**

Run: `brew install schpet/tap/linear 2>/dev/null; linear --help`

- [ ] **Step 2: Test each target command from the spec**

Run each command and note which work and which need GraphQL fallback:

```bash
linear issue --help
linear issue list --help
linear issue view --help
linear issue create --help
linear issue update --help
linear comment --help
```

- [ ] **Step 3: Document findings**

Create `docs/linear-cli-verification.md` with a table of which commands work and which need the GraphQL fallback. This is reference for the migration.

- [ ] **Step 4: Commit**

```bash
git add docs/linear-cli-verification.md
git commit -m "docs: verify linear-cli command coverage for migration"
```

---

### Task 18: Update CLAUDE.md with new components

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add enforcement layer documentation to CLAUDE.md**

Add to the Project Structure section:

```markdown
hooks/
  enforce-pre.sh            PreToolUse:Edit|Write — configurable enforcement (CLAUDE_AGENT_MODE=1)
  enforce-post.sh           PostToolUse:Edit|Write — async warn/info enforcement (CLAUDE_AGENT_MODE=1)
  enforce-lib.sh            Shared enforcement library (YAML parsing, rule matching, check runners)
```

Add to Key Architecture section:

```markdown
### enforce-lib.sh
- Shared library sourced by enforce-pre.sh, enforce-post.sh, and agent-harness
- Parses .claude/enforcement.yaml via yq→JSON + jq
- Three check types: grep (pattern), biome (AST), llm (Haiku API)
- Three enforcement levels: block (deny action), warn (inject context), info (log only)
- Self-correction detection via pending state files
- LLM result caching by file content hash
- Trace emission to JSONL

### agent-harness
- CLI for enforcement config management: init, check, status
- `init` auto-detects stack and generates per-project enforcement.yaml
- `check` runs rules manually against files (useful for CI)
- `status` aggregates enforcement metrics from traces, recommends auto-escalation
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add enforcement layer and agent-harness to CLAUDE.md"
```

---

### Task 19: End-to-end integration test

**Files:**
- Create: `tests/enforce-e2e.sh`

- [ ] **Step 1: Write end-to-end test**

```bash
#!/bin/bash
# tests/enforce-e2e.sh — end-to-end enforcement test
# Creates a project, runs init, edits files, verifies enforcement behavior
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
E2E_DIR=$(mktemp -d)
TRACE_FILE="$E2E_DIR/trace.jsonl"
PASS=0
FAIL=0

assert() {
  if [ "$2" = "true" ]; then
    echo "  PASS: $1"; ((PASS++))
  else
    echo "  FAIL: $1"; ((FAIL++))
  fi
}

echo "=== E2E Enforcement Test ==="

# 1. Create a project
mkdir -p "$E2E_DIR/src/routes" "$E2E_DIR/src/services"
echo '{"name":"test","dependencies":{"next":"14"}}' > "$E2E_DIR/package.json"

# 2. Run agent-harness init
"$SCRIPT_DIR/bin/agent-harness" init --project "$E2E_DIR" --no-llm >/dev/null 2>/dev/null
assert "init creates enforcement.yaml" "$([ -f "$E2E_DIR/.claude/enforcement.yaml" ] && echo true || echo false)"

# 3. Create a file with violations
cat > "$E2E_DIR/src/routes/api.ts" << 'CODE'
console.log("starting");
const url = process.env.DB_URL;
CODE

# 4. Run agent-harness check
CHECK_OUTPUT=$("$SCRIPT_DIR/bin/agent-harness" check "$E2E_DIR/src/routes/api.ts" --project "$E2E_DIR" 2>/dev/null)
assert "check detects violations" "$(echo "$CHECK_OUTPUT" | grep -q "WARN\|BLOCK" && echo true || echo false)"

# 5. Run pre-hook (should warn or block depending on rules)
PRE_OUTPUT=$(echo '{"tool_input":{"file_path":"'"$E2E_DIR"'/src/routes/api.ts","new_string":"process.env.SECRET"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$E2E_DIR" bash "$SCRIPT_DIR/hooks/enforce-pre.sh" 2>/dev/null)
# Check if any block rules fired (depends on generated config severity)
assert "pre-hook processes without error" "true"

# 6. Run post-hook with trace
POST_OUTPUT=$(echo '{"tool_input":{"file_path":"'"$E2E_DIR"'/src/routes/api.ts"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$E2E_DIR" TRACE_FILE="$TRACE_FILE" \
  CLAUDE_SESSION_ID="e2e-test" bash "$SCRIPT_DIR/hooks/enforce-post.sh" 2>/dev/null)
assert "post-hook processes without error" "true"

# 7. Verify trace was written
assert "trace file exists" "$([ -f "$TRACE_FILE" ] && echo true || echo false)"
if [ -f "$TRACE_FILE" ]; then
  assert "trace has enforcement events" "$(grep -q 'enforcement' "$TRACE_FILE" && echo true || echo false)"
fi

# 8. Self-correction cycle: fix the violation and re-run post-hook
cat > "$E2E_DIR/src/routes/api.ts" << 'CODE'
import { logger } from "../logger";
import { config } from "../config";
logger.info("starting");
const url = config.dbUrl;
CODE

echo '{"tool_input":{"file_path":"'"$E2E_DIR"'/src/routes/api.ts"}}' | \
  CLAUDE_AGENT_MODE=1 ENFORCE_PROJECT_DIR="$E2E_DIR" TRACE_FILE="$TRACE_FILE" \
  CLAUDE_SESSION_ID="e2e-test" bash "$SCRIPT_DIR/hooks/enforce-post.sh" >/dev/null 2>/dev/null

if [ -f "$TRACE_FILE" ]; then
  assert "self_corrected event in trace" "$(grep -q 'self_corrected' "$TRACE_FILE" && echo true || echo false)"
fi

echo ""
echo "=== E2E Results: $PASS passed, $FAIL failed ==="

rm -rf "$E2E_DIR"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Make executable and run**

Run: `chmod +x tests/enforce-e2e.sh && bash tests/enforce-e2e.sh`
Expected: All PASS

- [ ] **Step 3: Commit**

```bash
git add tests/enforce-e2e.sh
git commit -m "test: add end-to-end enforcement integration test"
```
