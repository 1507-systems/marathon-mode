#!/usr/bin/env bash
# statusline-quota.sh — Marathon Mode StatusLine quota display
#
# Reads Claude quota/session JSON from stdin (as provided by the StatusLine hook),
# writes a quota snapshot to /tmp for other tools to consume, and prints a
# human-readable display string to stdout for StatusLine to render.
#
# Input (stdin): StatusLine JSON with session_id and optional rate_limits block.
# Output (stdout): Display string, e.g.:
#   5h: 42% | 7d: 18% | resets: 2h13m | ZONE: GREEN | task 3/8
#   5h: 42% | 7d: 18% | resets: 2h13m      (no marathon state)
#   (empty string)                           (no rate_limits)
#
# Side effect: writes /tmp/marathon-quota-<SESSION_ID>.json

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency check — jq is required for JSON parsing
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  # Print nothing; StatusLine will show a blank segment rather than garbage
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Read all of stdin — StatusLine sends the full JSON payload at once
# ---------------------------------------------------------------------------
INPUT=$(cat)

# ---------------------------------------------------------------------------
# Extract session_id (may be empty if not present)
# ---------------------------------------------------------------------------
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# ---------------------------------------------------------------------------
# Check for rate_limits; if absent, output empty and exit
# ---------------------------------------------------------------------------
HAS_RATE_LIMITS=$(echo "$INPUT" | jq 'has("rate_limits")')

if [[ "$HAS_RATE_LIMITS" != "true" ]]; then
  # No quota data yet (non-subscriber or first message) — silent exit
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Extract five_hour and seven_day fields
# ---------------------------------------------------------------------------
FIVE_HOUR_PCT=$(echo "$INPUT"  | jq -r '.rate_limits.five_hour.used_percentage  // empty')
FIVE_HOUR_RESET=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at        // empty')
SEVEN_DAY_PCT=$(echo "$INPUT"  | jq -r '.rate_limits.seven_day.used_percentage  // empty')
SEVEN_DAY_RESET=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.resets_at        // empty')
IS_OVERAGE=$(echo "$INPUT"     | jq -r '.rate_limits.is_using_overage            // "false"')
OVERAGE_STATUS=$(echo "$INPUT" | jq -r '.rate_limits.overage_status              // "null"')

# ---------------------------------------------------------------------------
# Write quota snapshot to /tmp for other marathon tools to consume
# ---------------------------------------------------------------------------
if [[ -n "$SESSION_ID" ]]; then
  SNAPSHOT_FILE="/tmp/marathon-quota-${SESSION_ID}.json"
  NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -n \
    --arg fh_pct   "$FIVE_HOUR_PCT" \
    --argjson fh_reset  "${FIVE_HOUR_RESET:-0}" \
    --arg sd_pct   "$SEVEN_DAY_PCT" \
    --argjson sd_reset  "${SEVEN_DAY_RESET:-0}" \
    --argjson overage   "${IS_OVERAGE}" \
    --arg ovr_status "$OVERAGE_STATUS" \
    --arg updated   "$NOW_ISO" \
    '{
      five_hour:        { used_percentage: ($fh_pct | tonumber), resets_at: $fh_reset },
      seven_day:        { used_percentage: ($sd_pct | tonumber), resets_at: $sd_reset },
      is_using_overage: $overage,
      overage_status:   (if $ovr_status == "null" then null else $ovr_status end),
      updated_at:       $updated
    }' > "$SNAPSHOT_FILE"
fi

# ---------------------------------------------------------------------------
# Format percentage — round to integer for display
# ---------------------------------------------------------------------------
fmt_pct() {
  # Use printf to round; jq tonumber handles the float-to-int truncation
  printf "%.0f" "$1"
}

FIVE_PCT_DISPLAY=$(fmt_pct "${FIVE_HOUR_PCT:-0}")
SEVEN_PCT_DISPLAY=$(fmt_pct "${SEVEN_DAY_PCT:-0}")

# ---------------------------------------------------------------------------
# Calculate time-until-reset from five_hour.resets_at (the shorter window)
# ---------------------------------------------------------------------------
NOW_EPOCH=$(date +%s)
RESET_EPOCH="${FIVE_HOUR_RESET:-0}"

if [[ "$RESET_EPOCH" -gt "$NOW_EPOCH" ]]; then
  DIFF_SEC=$(( RESET_EPOCH - NOW_EPOCH ))
  DIFF_MIN=$(( DIFF_SEC / 60 ))
  HOURS=$(( DIFF_MIN / 60 ))
  MINS=$(( DIFF_MIN % 60 ))
  if [[ "$HOURS" -gt 0 ]]; then
    RESETS_DISPLAY="${HOURS}h${MINS}m"
  else
    RESETS_DISPLAY="${MINS}m"
  fi
else
  RESETS_DISPLAY="now"
fi

# ---------------------------------------------------------------------------
# Determine quota zone from five_hour percentage
#   GREEN  < 70%
#   YELLOW  70-84%
#   ORANGE  85-94%
#   RED    >= 95%
# ---------------------------------------------------------------------------
# Use awk for float comparison (bash can only do integer arithmetic)
ZONE=$(awk -v pct="${FIVE_HOUR_PCT:-0}" 'BEGIN {
  if (pct < 70)       print "GREEN"
  else if (pct < 85)  print "YELLOW"
  else if (pct < 95)  print "ORANGE"
  else                print "RED"
}')

# ---------------------------------------------------------------------------
# Read marathon state from .claude/marathon.local.md (if it exists)
# Look for current_task and total_tasks in YAML frontmatter
# ---------------------------------------------------------------------------
MARATHON_DISPLAY=""

# Determine the project CWD — StatusLine passes cwd via env or we fall back to pwd
# The file lives relative to wherever marathon is running, not this script
PROJECT_DIR="${MARATHON_CWD:-$(pwd)}"
MARATHON_FILE="${PROJECT_DIR}/.claude/marathon.local.md"

if [[ -f "$MARATHON_FILE" ]]; then
  # Extract frontmatter (content between the first pair of --- delimiters)
  FRONTMATTER=$(awk '/^---/{if(found) exit; found=1; next} found{print}' "$MARATHON_FILE")

  # Parse a key from frontmatter: "key: value"
  _parse_key() {
    local key="$1"
    echo "$FRONTMATTER" \
      | grep -E "^[[:space:]]*${key}[[:space:]]*:" \
      | head -n1 \
      | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" \
      | sed -E "s/[[:space:]]*$//" \
      | sed -E "s/^['\"]|['\"]$//g"
  }

  CURRENT_TASK=$(_parse_key "current_task")
  TOTAL_TASKS=$(_parse_key "total_tasks")

  # Only add marathon segment if both values are present and look like numbers
  if [[ -n "$CURRENT_TASK" && -n "$TOTAL_TASKS" ]] \
    && [[ "$CURRENT_TASK" =~ ^[0-9]+$ ]] \
    && [[ "$TOTAL_TASKS"  =~ ^[0-9]+$ ]]; then
    MARATHON_DISPLAY="task ${CURRENT_TASK}/${TOTAL_TASKS}"
  fi
fi

# ---------------------------------------------------------------------------
# Build and emit the final display string
# ---------------------------------------------------------------------------
BASE="5h: ${FIVE_PCT_DISPLAY}% | 7d: ${SEVEN_PCT_DISPLAY}% | resets: ${RESETS_DISPLAY} | ZONE: ${ZONE}"

if [[ -n "$MARATHON_DISPLAY" ]]; then
  echo "${BASE} | ${MARATHON_DISPLAY}"
else
  echo "${BASE}"
fi
