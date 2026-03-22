#!/usr/bin/env bash
# watchdog.sh — Marathon Mode subagent stall detector
#
# Monitors registered subagents for inactivity. If an agent's JSONL output file
# has not been updated within STALL_TIMEOUT_MIN minutes, the agent is considered
# stalled: it is killed, the task is marked FAILED in the task file, a stall log
# entry is written, a notification is dispatched, and (if retries remain) a retry
# entry is added to the registry with an escalated model.
#
# Usage: watchdog.sh <SESSION_ID> [--stall-timeout 15] [--max-retries 1] [--check-interval 60]
#
# Registry: /tmp/marathon-agents-{SESSION_ID}.json
# Stall log: /tmp/marathon-stall-log-{SESSION_ID}.jsonl

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SESSION_ID> [--stall-timeout <min>] [--max-retries <n>] [--check-interval <sec>]" >&2
  exit 1
fi

SESSION_ID="$1"
shift

STALL_TIMEOUT_MIN=15
MAX_RETRIES=1
CHECK_INTERVAL=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stall-timeout)   STALL_TIMEOUT_MIN="$2"; shift 2 ;;
    --max-retries)     MAX_RETRIES="$2";        shift 2 ;;
    --check-interval)  CHECK_INTERVAL="$2";     shift 2 ;;
    *) echo "[watchdog] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

if ! command -v jq &>/dev/null; then
  echo "[watchdog] ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# File paths
# ---------------------------------------------------------------------------

REGISTRY="/tmp/marathon-agents-${SESSION_ID}.json"
STALL_LOG="/tmp/marathon-stall-log-${SESSION_ID}.jsonl"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_SCRIPT="${SCRIPT_DIR}/notify.sh"

# ---------------------------------------------------------------------------
# Signal handling — clean exit on SIGTERM
# ---------------------------------------------------------------------------

RUNNING=true
trap 'echo "[watchdog] $(date -u +%Y-%m-%dT%H:%M:%SZ) Received SIGTERM, exiting." >&2; RUNNING=false' TERM INT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  # Write a timestamped line to stderr for debugging
  echo "[watchdog] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

# Get file modification time in epoch seconds.
# Tries macOS stat first, falls back to GNU/Linux stat.
file_mtime() {
  local path="$1"
  if stat -f %m "$path" 2>/dev/null; then
    return
  fi
  stat -c %Y "$path" 2>/dev/null
}

# Current UTC epoch seconds
now_epoch() {
  date -u +%s
}

# Model escalation: haiku -> sonnet -> opus -> opus (no further escalation)
escalate_model() {
  local model="$1"
  case "$model" in
    *haiku*)  echo "sonnet" ;;
    *sonnet*) echo "opus"   ;;
    *)        echo "opus"   ;;
  esac
}

# Parse the tasks_file path from the YAML frontmatter of .claude/marathon.local.md
# in the agent's working_dir.
get_tasks_file() {
  local working_dir="$1"
  local config="${working_dir}/.claude/marathon.local.md"
  if [[ ! -f "$config" ]]; then
    return 1
  fi
  # Extract frontmatter between the first pair of --- delimiters, then grep tasks_file
  awk '/^---/{if(found) exit; found=1; next} found{print}' "$config" \
    | grep -E '^[[:space:]]*tasks_file[[:space:]]*:' | head -n1 \
    | sed -E 's/^[[:space:]]*tasks_file[[:space:]]*:[[:space:]]*//' \
    | sed -E "s/[[:space:]]*$//" \
    | sed -E "s/^['\"]|['\"]$//g"
}

# Mark a task as FAILED in the task file.
# Finds the line matching the task_id comment anchor (<!-- task_id: N -->) or
# the first checkbox line that contains the task description, and rewrites the
# checkbox state to [FAILED].
mark_task_failed() {
  local tasks_file="$1"
  local task_id="$2"
  local description="$3"

  if [[ ! -f "$tasks_file" ]]; then
    log "WARN: tasks file not found: $tasks_file — cannot mark task $task_id as FAILED"
    return
  fi

  # Strategy 1: look for a task_id comment anchor on the same line or preceding line
  # Strategy 2: fall back to matching the description text in a checkbox line
  # We use a Python one-liner for safe in-place editing (macOS sed -i requires a backup suffix)
  python3 - "$tasks_file" "$task_id" "$description" <<'PYEOF'
import sys, re

tasks_file = sys.argv[1]
task_id    = sys.argv[2]
description= sys.argv[3]

with open(tasks_file, 'r') as f:
    lines = f.readlines()

# Pattern: a markdown checkbox line (- [ ], - [x], - [X], - [FAILED], etc.)
checkbox_re = re.compile(r'^(\s*-\s*\[)[^\]]*(\].*)')

# Try to find the line by task_id anchor comment first
anchor = f'task_id: {task_id}'
replaced = False
for i, line in enumerate(lines):
    if anchor in line and checkbox_re.search(line):
        lines[i] = checkbox_re.sub(r'\1FAILED\2', line)
        replaced = True
        break

# Fallback: match by description substring in a checkbox line
if not replaced and description:
    for i, line in enumerate(lines):
        if description[:40] in line and checkbox_re.search(line):
            lines[i] = checkbox_re.sub(r'\1FAILED\2', line)
            replaced = True
            break

if replaced:
    with open(tasks_file, 'w') as f:
        f.writelines(lines)
    print(f"Marked task {task_id} as FAILED in {tasks_file}")
else:
    print(f"WARN: could not locate task {task_id} in {tasks_file}", file=sys.stderr)
PYEOF
}

# ---------------------------------------------------------------------------
# Main check loop
# ---------------------------------------------------------------------------

log "Starting. session=$SESSION_ID stall_timeout=${STALL_TIMEOUT_MIN}m max_retries=$MAX_RETRIES check_interval=${CHECK_INTERVAL}s"

while [[ "$RUNNING" == "true" ]]; do
  sleep "$CHECK_INTERVAL" &
  SLEEP_PID=$!
  # Wait for sleep, but allow SIGTERM to interrupt us cleanly
  wait "$SLEEP_PID" 2>/dev/null || true

  # Re-check RUNNING after waking (SIGTERM may have arrived during sleep)
  [[ "$RUNNING" == "true" ]] || break

  # Registry must exist to proceed
  if [[ ! -f "$REGISTRY" ]]; then
    log "Registry not found yet: $REGISTRY — waiting."
    continue
  fi

  NOW="$(now_epoch)"
  STALL_THRESHOLD_SEC=$(( STALL_TIMEOUT_MIN * 60 ))

  # Read the full registry once per iteration
  REGISTRY_JSON="$(cat "$REGISTRY")"

  # Iterate over each registered agent
  AGENT_COUNT="$(echo "$REGISTRY_JSON" | jq '.agents | length')"

  for (( idx=0; idx<AGENT_COUNT; idx++ )); do
    AGENT="$(echo "$REGISTRY_JSON" | jq ".agents[$idx]")"

    TASK_ID="$(echo "$AGENT"    | jq -r '.task_id')"
    PID="$(echo "$AGENT"        | jq -r '.pid')"
    JSONL_PATH="$(echo "$AGENT" | jq -r '.jsonl_path')"
    MODEL="$(echo "$AGENT"      | jq -r '.model')"
    DESCRIPTION="$(echo "$AGENT"| jq -r '.description')"
    RETRY_COUNT="$(echo "$AGENT"| jq -r '.retry_count // 0')"
    WORKING_DIR="$(echo "$AGENT"| jq -r '.working_dir')"

    # Skip if JSONL file doesn't exist yet — agent may still be initialising
    if [[ ! -f "$JSONL_PATH" ]]; then
      log "Agent task=$TASK_ID: JSONL not found ($JSONL_PATH), skipping."
      continue
    fi

    MTIME="$(file_mtime "$JSONL_PATH")"
    ELAPSED_SEC=$(( NOW - MTIME ))
    ELAPSED_MIN=$(( ELAPSED_SEC / 60 ))

    if [[ "$ELAPSED_SEC" -le "$STALL_THRESHOLD_SEC" ]]; then
      # Agent is active — nothing to do
      continue
    fi

    log "STALL detected: task=$TASK_ID pid=$PID model=$MODEL idle=${ELAPSED_MIN}m"

    # ------------------------------------------------------------------
    # 1. Kill the stalled agent
    # ------------------------------------------------------------------
    if kill -0 "$PID" 2>/dev/null; then
      log "Sending SIGTERM to pid=$PID"
      kill -TERM "$PID" 2>/dev/null || true
      sleep 5
      if kill -0 "$PID" 2>/dev/null; then
        log "pid=$PID still alive after 5s — sending SIGKILL"
        kill -KILL "$PID" 2>/dev/null || true
      fi
    else
      log "pid=$PID is already gone."
    fi

    # ------------------------------------------------------------------
    # 2. Mark task FAILED in the task file
    # ------------------------------------------------------------------
    TASKS_FILE=""
    if TASKS_FILE="$(get_tasks_file "$WORKING_DIR")" && [[ -n "$TASKS_FILE" ]]; then
      # tasks_file may be relative to working_dir
      if [[ "$TASKS_FILE" != /* ]]; then
        TASKS_FILE="${WORKING_DIR}/${TASKS_FILE}"
      fi
      mark_task_failed "$TASKS_FILE" "$TASK_ID" "$DESCRIPTION"
    else
      log "WARN: could not resolve tasks_file for task=$TASK_ID (working_dir=$WORKING_DIR)"
    fi

    # ------------------------------------------------------------------
    # 3. Append to stall log
    # ------------------------------------------------------------------
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    RETRY_MODEL="$(escalate_model "$MODEL")"

    # Determine action label
    if [[ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]]; then
      ACTION="killed+retry"
    else
      ACTION="killed+permanent_fail"
    fi

    jq -cn \
      --argjson task_id "$TASK_ID" \
      --arg     model      "$MODEL" \
      --argjson stalled_min "$ELAPSED_MIN" \
      --arg     action     "$ACTION" \
      --arg     retry_model "$RETRY_MODEL" \
      --arg     ts         "$TS" \
      '{task_id: $task_id, model: $model, stalled_min: $stalled_min, action: $action, retry_model: $retry_model, ts: $ts}' \
      >> "$STALL_LOG"

    log "Stall log entry written to $STALL_LOG"

    # ------------------------------------------------------------------
    # 4. Send notification
    # ------------------------------------------------------------------
    NOTIF_MSG="Task ${TASK_ID} stalled (${ELAPSED_MIN}m). Killed and ${ACTION}."
    if [[ -x "$NOTIFY_SCRIPT" ]]; then
      "$NOTIFY_SCRIPT" "Agent Stalled" "$NOTIF_MSG" "$WORKING_DIR" || true
    else
      log "WARN: notify script not found or not executable: $NOTIFY_SCRIPT"
    fi

    # ------------------------------------------------------------------
    # 5. Queue retry if under the retry limit
    # ------------------------------------------------------------------
    if [[ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]]; then
      log "Queuing retry for task=$TASK_ID with model=$RETRY_MODEL (retry $((RETRY_COUNT + 1))/$MAX_RETRIES)"

      # Add a retry entry and remove the stalled agent from the active list
      UPDATED_REGISTRY="$(echo "$REGISTRY_JSON" | jq \
        --argjson task_id "$TASK_ID" \
        --arg     model   "$RETRY_MODEL" \
        --arg     queued  "$TS" \
        '(.agents |= map(select(.task_id != $task_id)))
         | .retries += [{"task_id": $task_id, "model": $model, "reason": "stall_escalation", "queued_at": $queued}]')"

      echo "$UPDATED_REGISTRY" > "$REGISTRY"
      # Reload for subsequent iterations within this loop
      REGISTRY_JSON="$UPDATED_REGISTRY"
    else
      log "Max retries ($MAX_RETRIES) reached for task=$TASK_ID — permanent FAILED."
      # Remove the stalled agent from the active list
      UPDATED_REGISTRY="$(echo "$REGISTRY_JSON" | jq \
        --argjson task_id "$TASK_ID" \
        '.agents |= map(select(.task_id != $task_id))')"
      echo "$UPDATED_REGISTRY" > "$REGISTRY"
      REGISTRY_JSON="$UPDATED_REGISTRY"
    fi

  done # end agent loop

done # end main loop

log "Watchdog exiting cleanly."
