#!/usr/bin/env bash
# stop-hook.sh — Marathon Mode Stop hook for task cycling in orchestrate mode.
#
# Fires when Claude tries to exit/stop. In orchestrate mode, intercepts the
# stop signal and feeds the next unchecked task as a new prompt, keeping the
# session alive until all tasks are complete (or quota/wake constraints apply).
#
# Input (JSON on stdin):
#   { "session_id": "...", "transcript_path": "...", "cwd": "..." }
#
# Exit codes:
#   0 — allow Claude to exit (no block)
#   outputs JSON { "decision": "block", "reason": "...", "systemMessage": "..." }
#     when blocking the stop signal to continue with next task.

set -euo pipefail

# ---------------------------------------------------------------------------
# Read and parse hook input from stdin
# ---------------------------------------------------------------------------

INPUT="$(cat)"

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // ""')"
# shellcheck disable=SC2034  # TRANSCRIPT_PATH: parsed per hook contract; reserved for future quota cross-checking
TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // ""')"
CWD="$(echo "$INPUT" | jq -r '.cwd // ""')"

# Fall back to process cwd if not provided
if [[ -z "$CWD" ]]; then
  CWD="$(pwd)"
fi

# ---------------------------------------------------------------------------
# Check for marathon state file — if absent, this session is not managed
# ---------------------------------------------------------------------------

STATE_FILE="${CWD}/.claude/marathon.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse YAML frontmatter from the state file
# Lines between the first pair of --- delimiters.
# ---------------------------------------------------------------------------

FRONTMATTER="$(awk '/^---/{if(found) exit; found=1; next} found{print}' "$STATE_FILE")"

# Parse a single key: value pair from the frontmatter, stripping whitespace
# and surrounding quotes. Returns empty string if key not found.
_parse_key() {
  local key="$1"
  echo "$FRONTMATTER" | grep -E "^[[:space:]]*${key}[[:space:]]*:" | head -n1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" \
    | sed -E "s/[[:space:]]*$//" \
    | sed -E "s/^['\"]|['\"]$//g"
}

STATE_SESSION_ID="$(_parse_key "session_id")"
MODE="$(_parse_key "mode")"
CURRENT_TASK="$(_parse_key "current_task")"
TOTAL_TASKS="$(_parse_key "total_tasks")"
QUOTA_ZONE="$(_parse_key "quota_zone")"
TASKS_FILE="$(_parse_key "tasks_file")"
WAKE_TIME="$(_parse_key "wake_time")"

# ---------------------------------------------------------------------------
# Guard: only manage sessions that match the state file's session_id
# ---------------------------------------------------------------------------

if [[ -z "$STATE_SESSION_ID" || "$STATE_SESSION_ID" != "$SESSION_ID" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: only act in orchestrate mode (advisory mode lets Claude exit freely)
# ---------------------------------------------------------------------------

if [[ "$MODE" != "orchestrate" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: coast and red quota zones — allow clean exit to avoid burning quota
# ---------------------------------------------------------------------------

if [[ "$QUOTA_ZONE" == "coast" || "$QUOTA_ZONE" == "red" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: wake_time — if a scheduled wake time is set and it's < 30 min away,
# let the session end now so it can restart fresh at the right time.
# wake_time is HH:MM (24-hour). If that time is earlier than now, treat as
# tomorrow's time.
# ---------------------------------------------------------------------------

if [[ -n "$WAKE_TIME" && "$WAKE_TIME" != "null" ]]; then
  NOW_H=$(date +%H)
  NOW_M=$(date +%M)
  NOW_TOTAL=$(( (10#$NOW_H * 60) + 10#$NOW_M ))

  WAKE_H="${WAKE_TIME%%:*}"
  WAKE_M="${WAKE_TIME##*:}"
  WAKE_TOTAL=$(( (10#$WAKE_H * 60) + 10#$WAKE_M ))

  # If wake time is earlier or equal to now, it refers to tomorrow — add 24h
  if [[ $WAKE_TOTAL -le $NOW_TOTAL ]]; then
    WAKE_TOTAL=$(( WAKE_TOTAL + 1440 ))
  fi

  MINS_UNTIL_WAKE=$(( WAKE_TOTAL - NOW_TOTAL ))

  if [[ $MINS_UNTIL_WAKE -lt 30 ]]; then
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Load the tasks file and find unchecked tasks
# ---------------------------------------------------------------------------

# tasks_file may be absolute or relative to cwd
if [[ -z "$TASKS_FILE" ]]; then
  exit 0
fi

if [[ "$TASKS_FILE" != /* ]]; then
  TASKS_FILE="${CWD}/${TASKS_FILE}"
fi

if [[ ! -f "$TASKS_FILE" ]]; then
  exit 0
fi

# Count all unchecked tasks
UNCHECKED_COUNT=$(grep -c "^- \[ \]" "$TASKS_FILE" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# No remaining tasks — run is complete
# ---------------------------------------------------------------------------

if [[ "$UNCHECKED_COUNT" -eq 0 ]]; then
  # Move the state file to Trash — do not use rm per project file ops policy
  mv "$STATE_FILE" ~/.Trash/ 2>/dev/null || true

  # Send a completion notification
  NOTIFY_SCRIPT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/scripts/notify.sh"
  if [[ -x "$NOTIFY_SCRIPT" ]]; then
    "$NOTIFY_SCRIPT" "Marathon Complete" \
      "All ${TOTAL_TASKS} tasks finished." \
      "$CWD" || true
  fi

  exit 0
fi

# ---------------------------------------------------------------------------
# Find the next unchecked task (first `- [ ]` line)
# ---------------------------------------------------------------------------

# Read the tasks file line by line to find the first unchecked task and its
# optional model hint on the immediately following line.
NEXT_TASK_DESC=""
MODEL_HINT=""
NEXT_LINE_IS_HINT=false

while IFS= read -r line; do
  if $NEXT_LINE_IS_HINT; then
    # Check whether this line contains a model hint comment
    if echo "$line" | grep -qE "^[[:space:]]*<!--[[:space:]]*model:[[:space:]]*(opus|sonnet|haiku)[[:space:]]*-->"; then
      MODEL_HINT=$(echo "$line" | sed -E "s/.*<!--[[:space:]]*model:[[:space:]]*//" | sed -E "s/[[:space:]]*-->.*//" | sed -E "s/[[:space:]]*$//")
    fi
    NEXT_LINE_IS_HINT=false
    break
  fi

  if echo "$line" | grep -qE "^- \[ \] "; then
    # Extract task description (everything after `- [ ] `)
    NEXT_TASK_DESC="${line#- \[ \] }"
    NEXT_LINE_IS_HINT=true
    # Don't break yet — need to peek at the next line for the model hint
  fi
done < "$TASKS_FILE"

if [[ -z "$NEXT_TASK_DESC" ]]; then
  # Couldn't parse a task — allow exit rather than looping on nothing
  exit 0
fi

# ---------------------------------------------------------------------------
# Increment current_task counter in the state file
# ---------------------------------------------------------------------------

NEXT_TASK_NUM=$(( ${CURRENT_TASK:-0} + 1 ))

# Update the current_task field in the frontmatter via sed (in-place)
sed -i '' -E "s/^([[:space:]]*current_task[[:space:]]*:[[:space:]]*)[0-9]+/\1${NEXT_TASK_NUM}/" "$STATE_FILE"

# ---------------------------------------------------------------------------
# Build the prompt for the next task
# ---------------------------------------------------------------------------

# Append model hint instruction if present
MODEL_NOTE=""
if [[ -n "$MODEL_HINT" ]]; then
  MODEL_NOTE="

Preferred model for this task: ${MODEL_HINT}"
fi

PROMPT="$(cat <<PROMPT
Task ${NEXT_TASK_NUM}/${TOTAL_TASKS}: ${NEXT_TASK_DESC}${MODEL_NOTE}

MARATHON DISCIPLINE RULES:
1. Commit your changes before finishing — do not leave uncommitted work.
2. Update PROJECT_LOG.md with what you did — include what changed and why.
3. Only work on this specific task — do not start other tasks or "while I'm here" fixes.
4. If blocked, document the blocker in the task file and complete without resolving it.
PROMPT
)"

SYSTEM_MSG="Marathon: Starting task ${NEXT_TASK_NUM}/${TOTAL_TASKS}"

# ---------------------------------------------------------------------------
# Send notification
# ---------------------------------------------------------------------------

NOTIFY_SCRIPT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/scripts/notify.sh"
if [[ -x "$NOTIFY_SCRIPT" ]]; then
  "$NOTIFY_SCRIPT" "Marathon" \
    "Starting task ${NEXT_TASK_NUM}/${TOTAL_TASKS}: ${NEXT_TASK_DESC}" \
    "$CWD" || true
fi

# ---------------------------------------------------------------------------
# Output block decision — prevents Claude from stopping and injects next task
# ---------------------------------------------------------------------------

jq -n \
  --arg reason "$PROMPT" \
  --arg systemMessage "$SYSTEM_MSG" \
  '{
    decision: "block",
    reason: $reason,
    systemMessage: $systemMessage
  }'
