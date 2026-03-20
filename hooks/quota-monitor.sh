#!/usr/bin/env bash
# quota-monitor.sh — PostToolUse hook: monitors quota zone and emits a
# systemMessage when the zone changes (GREEN/YELLOW/ORANGE/RED/COAST).
#
# Fires after EVERY tool call, so it must exit fast.
# Target: < 200ms on the happy path (no zone change).
#
# Input (stdin): JSON hook payload from Claude Code
# Output (stdout): JSON {"systemMessage": "..."} on zone transition, else empty

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency guard — jq is required; fail silently so the session isn't broken
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Read hook payload from stdin
# ---------------------------------------------------------------------------
HOOK_INPUT=$(cat)

SESSION_ID=$(echo "$HOOK_INPUT"      | jq -r '.session_id      // empty')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$HOOK_INPUT"             | jq -r '.cwd             // empty')

# If we can't determine where we are, bail out silently
if [[ -z "$CWD" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Check that marathon is active in this project
# ---------------------------------------------------------------------------
STATE_FILE="${CWD}/.claude/marathon.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  # No marathon state — this project is not running marathon mode
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse YAML frontmatter from the state file
# Frontmatter lives between the first pair of --- delimiters
# ---------------------------------------------------------------------------
FRONTMATTER=$(awk '/^---/{if(found) exit; found=1; next} found{print}' "$STATE_FILE")

# Helper: extract a single key value from frontmatter
_parse_key() {
  local key="$1"
  echo "$FRONTMATTER" \
    | grep -E "^[[:space:]]*${key}[[:space:]]*:" \
    | head -n1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" \
    | sed -E "s/[[:space:]]*$//" \
    | sed -E "s/^['\"]|['\"]$//g"
}

STATE_SESSION_ID=$(_parse_key "session_id")
CURRENT_ZONE=$(_parse_key "quota_zone")
TASKS_FILE=$(_parse_key "tasks_file")

# ---------------------------------------------------------------------------
# Session guard — only monitor the session that owns this state file
# ---------------------------------------------------------------------------
if [[ -n "$STATE_SESSION_ID" && -n "$SESSION_ID" ]]; then
  if [[ "$SESSION_ID" != "$STATE_SESSION_ID" ]]; then
    # Different session — don't touch this project's state
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Determine CLAUDE_PLUGIN_ROOT — the directory containing this script's parent
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Run quota-check.sh to get the current zone
# Falls back to "unknown" if the script fails or quota data is unavailable
# ---------------------------------------------------------------------------
QUOTA_JSON=$("${PLUGIN_ROOT}/scripts/quota-check.sh" \
  "${SESSION_ID:-unknown}" \
  "${TRANSCRIPT_PATH:-/dev/null}" 2>/dev/null \
  || echo '{"zone":"unknown","five_hour_pct":null,"resets_in_min":null}')

NEW_ZONE=$(echo "$QUOTA_JSON" | jq -r '.zone // "unknown"')

# ---------------------------------------------------------------------------
# Early exit if zone has not changed (the common case — must be fast)
# ---------------------------------------------------------------------------
if [[ "$NEW_ZONE" == "$CURRENT_ZONE" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Zone has changed — update the state file
# ---------------------------------------------------------------------------
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PCT=$(echo "$QUOTA_JSON" | jq -r '.five_hour_pct // "null"')

# Round percentage to integer for display (awk handles null gracefully)
PCT_INT=$(awk -v p="$PCT" 'BEGIN { if (p == "null" || p == "") print "?"; else printf "%d", p+0.5 }')

# Persist zone change into the frontmatter via sed in-place replacements.
# Each sed call targets the specific key on its own line.
# macOS sed requires an empty string for -i when no backup is wanted.
sed -i '' -E \
  "s|^([[:space:]]*quota_zone[[:space:]]*:[[:space:]]*).*|\1${NEW_ZONE}|" \
  "$STATE_FILE"

sed -i '' -E \
  "s|^([[:space:]]*last_check_pct[[:space:]]*:[[:space:]]*).*|\1${PCT_INT}|" \
  "$STATE_FILE"

sed -i '' -E \
  "s|^([[:space:]]*last_check_at[[:space:]]*:[[:space:]]*).*|\1${NOW_ISO}|" \
  "$STATE_FILE"

# ---------------------------------------------------------------------------
# Count remaining unchecked tasks from the tasks file
# ---------------------------------------------------------------------------
REMAINING_TASKS=0
if [[ -n "$TASKS_FILE" && -f "$TASKS_FILE" ]]; then
  REMAINING_TASKS=$(grep -c '^\s*- \[ \]' "$TASKS_FILE" 2>/dev/null || echo 0)
elif [[ -n "$TASKS_FILE" && -f "${CWD}/${TASKS_FILE}" ]]; then
  REMAINING_TASKS=$(grep -c '^\s*- \[ \]' "${CWD}/${TASKS_FILE}" 2>/dev/null || echo 0)
fi

# ---------------------------------------------------------------------------
# Format resets_in_min as human-readable (e.g. "1h42m" or "38m")
# ---------------------------------------------------------------------------
RESETS_IN_MIN=$(echo "$QUOTA_JSON" | jq -r '.resets_in_min // "null"')

fmt_resets() {
  local raw="$1"
  if [[ "$raw" == "null" || -z "$raw" ]]; then
    echo "unknown"
    return
  fi
  # raw is an integer number of minutes
  local mins
  mins=$(printf "%.0f" "$raw" 2>/dev/null || echo "$raw")
  if [[ "$mins" -le 0 ]]; then
    echo "now"
  elif [[ "$mins" -ge 60 ]]; then
    local h=$(( mins / 60 ))
    local m=$(( mins % 60 ))
    echo "${h}h${m}m"
  else
    echo "${mins}m"
  fi
}

RESETS_HUMAN=$(fmt_resets "$RESETS_IN_MIN")

# ---------------------------------------------------------------------------
# Build the systemMessage based on the new zone
# ---------------------------------------------------------------------------
NEW_ZONE_UPPER=$(echo "$NEW_ZONE" | tr '[:lower:]' '[:upper:]')
case "$NEW_ZONE_UPPER" in
  GREEN)
    SYS_MSG="🟢 GREEN: Quota reset. Resuming full speed. ${REMAINING_TASKS} tasks remaining."
    ;;
  YELLOW)
    SYS_MSG="⚠️ YELLOW: ${PCT_INT}% used, resets in ${RESETS_HUMAN}. Finish current task, then sequential only. Downshift complex tasks to Sonnet."
    ;;
  ORANGE)
    SYS_MSG="🟠 ORANGE: ${PCT_INT}% used. Wind down: commit all work, update docs, push. Downshift all models one tier."
    ;;
  RED)
    SYS_MSG="🔴 RED: ${PCT_INT}% used. Emergency save. Commit WIP, push, notify, stop."
    ;;
  COAST)
    SYS_MSG="🔵 COAST: ${PCT_INT}% used, resets in ${RESETS_HUMAN}. Saving state and exiting. Scheduler will restart session after reset."
    ;;
  *)
    # Unknown zone — don't emit a message, just exit
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Send a push notification for YELLOW and above (not GREEN)
# Run in background so it doesn't block the hook's return
# ---------------------------------------------------------------------------
case "$NEW_ZONE_UPPER" in
  YELLOW|ORANGE|RED|COAST)
    "${PLUGIN_ROOT}/scripts/notify.sh" \
      "Marathon Mode — Zone: ${NEW_ZONE_UPPER}" \
      "$SYS_MSG" \
      "$CWD" &>/dev/null &
    ;;
esac

# ---------------------------------------------------------------------------
# Emit the systemMessage JSON — Claude Code injects this into the conversation
# ---------------------------------------------------------------------------
jq -n --arg msg "$SYS_MSG" '{"systemMessage": $msg}'
