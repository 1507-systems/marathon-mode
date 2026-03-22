#!/usr/bin/env bash
# quota-check.sh — Read Claude quota data and output a JSON summary.
#
# Usage: quota-check.sh <SESSION_ID> <TRANSCRIPT_PATH> [--registry /path/to/registry.json]
#
# Primary path: reads /tmp/marathon-quota-<SESSION_ID>.json written by the
#   StatusLine hook (expires after 5 minutes).
# Multi-session path: if --registry is provided and file exists, aggregates token
#   usage from all subagent JSONL files plus the parent transcript.
# Fallback path: parses the JSONL transcript to estimate usage from token counts.
#
# Outputs a single JSON object to stdout.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <SESSION_ID> <TRANSCRIPT_PATH> [--registry /path/to/registry.json]" >&2
  exit 1
fi

SESSION_ID="$1"
TRANSCRIPT_PATH="$2"

# Parse optional --registry argument
REGISTRY_FILE=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      REGISTRY_FILE="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not found in PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helper: emit the "unknown" response when no data is available
# ---------------------------------------------------------------------------

emit_unknown() {
  jq -n '{
    zone: "unknown",
    five_hour_pct: null,
    seven_day_pct: null,
    resets_at: null,
    resets_in_min: null,
    is_using_overage: null,
    source: "none"
  }'
}

# ---------------------------------------------------------------------------
# Helper: determine zone from percentages and 429 signal
# ---------------------------------------------------------------------------
# Args: $1=five_hour_pct (float), $2=seven_day_pct (float or "null"),
#       $3=resets_at (epoch int or "null"), $4=rate_limited ("true"/"false")
# Prints one of: green / yellow / orange / red / coast

calculate_zone() {
  local five_pct="$1"
  local seven_pct="$2"
  local resets_at="$3"
  local rate_limited="$4"

  local now
  now=$(date +%s)

  # Force red when rate-limited (429 detected)
  if [[ "$rate_limited" == "true" ]]; then
    # COAST: rate-limited AND resets within 45 minutes
    if [[ "$resets_at" != "null" && "$resets_at" -gt 0 ]]; then
      local mins_until_reset=$(( (resets_at - now) / 60 ))
      if [[ $mins_until_reset -le 45 ]]; then
        echo "coast"
        return
      fi
    fi
    echo "red"
    return
  fi

  # Use bc for floating-point comparison
  local pct_int
  pct_int=$(printf "%.0f" "$five_pct" 2>/dev/null || echo "0")

  if [[ $pct_int -gt 95 ]]; then
    # COAST: very high usage AND resets within 45 minutes
    if [[ "$resets_at" != "null" && "$resets_at" -gt 0 ]]; then
      local mins_until_reset=$(( (resets_at - now) / 60 ))
      if [[ $mins_until_reset -le 45 ]]; then
        echo "coast"
        return
      fi
    fi
    echo "red"
    return
  fi

  if [[ $pct_int -ge 85 ]]; then
    echo "orange"
    return
  fi

  if [[ $pct_int -ge 70 ]]; then
    echo "yellow"
    return
  fi

  # Also yellow if seven-day is over 90 (when data is available)
  if [[ "$seven_pct" != "null" ]]; then
    local seven_int
    seven_int=$(printf "%.0f" "$seven_pct" 2>/dev/null || echo "0")
    if [[ $seven_int -gt 90 ]]; then
      echo "yellow"
      return
    fi
  fi

  echo "green"
}

# ---------------------------------------------------------------------------
# Primary path — StatusLine cache file
# ---------------------------------------------------------------------------

QUOTA_CACHE="/tmp/marathon-quota-${SESSION_ID}.json"

if [[ -f "$QUOTA_CACHE" ]]; then
  # Check file age — reject if older than 5 minutes (300 seconds)
  now_epoch=$(date +%s)
  file_mtime=$(stat -f %m "$QUOTA_CACHE" 2>/dev/null || stat -c %Y "$QUOTA_CACHE" 2>/dev/null || echo 0)
  age=$(( now_epoch - file_mtime ))

  if [[ $age -lt 300 ]]; then
    # Extract fields from the StatusLine JSON blob
    five_pct=$(jq -r '.five_hour.used_percentage // "null"' "$QUOTA_CACHE")
    five_resets=$(jq -r '.five_hour.resets_at // "null"' "$QUOTA_CACHE")
    seven_pct=$(jq -r '.seven_day.used_percentage // "null"' "$QUOTA_CACHE")
    is_overage=$(jq -r '.is_using_overage // false' "$QUOTA_CACHE")

    if [[ "$five_pct" != "null" ]]; then
      # Use the five-hour resets_at as the primary timer
      resets_at="$five_resets"

      # Calculate minutes until reset
      if [[ "$resets_at" != "null" && "$resets_at" -gt 0 ]]; then
        resets_in_min=$(( (resets_at - now_epoch) / 60 ))
        # Clamp to 0 if already past
        [[ $resets_in_min -lt 0 ]] && resets_in_min=0
      else
        resets_in_min="null"
      fi

      zone=$(calculate_zone "$five_pct" "$seven_pct" "$resets_at" "false")

      jq -n \
        --arg zone "$zone" \
        --argjson five_pct "$five_pct" \
        --argjson seven_pct "${seven_pct}" \
        --argjson resets_at "${resets_at}" \
        --argjson resets_in_min "${resets_in_min}" \
        --argjson is_overage "$is_overage" \
        '{
          zone: $zone,
          five_hour_pct: $five_pct,
          seven_day_pct: $seven_pct,
          resets_at: $resets_at,
          resets_in_min: $resets_in_min,
          is_using_overage: $is_overage,
          source: "statusline"
        }'
      exit 0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Multi-session aggregation path — agent registry
# ---------------------------------------------------------------------------

if [[ -n "$REGISTRY_FILE" && -f "$REGISTRY_FILE" ]]; then
  # Collect all subagent JSONL paths from the registry
  mapfile -t AGENT_JSONL_PATHS < <(jq -r '.agents[].jsonl_path // empty' "$REGISTRY_FILE" 2>/dev/null || true)

  TOTAL_MULTI_TOKENS=0
  AGENT_COUNT="${#AGENT_JSONL_PATHS[@]}"

  # Sum tokens from each subagent JSONL file
  for jsonl in "${AGENT_JSONL_PATHS[@]}"; do
    if [[ -f "$jsonl" ]]; then
      agent_tokens=$(
        grep '"type":"assistant"' "$jsonl" 2>/dev/null \
          | jq -r '.message.usage.output_tokens // 0' 2>/dev/null \
          | awk '{sum+=$1} END {print (sum ? sum : 0)}'
      )
      TOTAL_MULTI_TOKENS=$(( TOTAL_MULTI_TOKENS + agent_tokens ))
    fi
  done

  # Add the parent transcript tokens (counted once — not in registry)
  if [[ -f "$TRANSCRIPT_PATH" ]]; then
    parent_tokens=$(
      grep '"type":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null \
        | jq -r '.message.usage.output_tokens // 0' 2>/dev/null \
        | awk '{sum+=$1} END {print (sum ? sum : 0)}'
    )
    TOTAL_MULTI_TOKENS=$(( TOTAL_MULTI_TOKENS + parent_tokens ))
  fi

  # Estimate five-hour percentage across all sessions (45,000,000 output tokens = 100%)
  multi_estimated_pct=$(awk "BEGIN { printf \"%.4f\", ($TOTAL_MULTI_TOKENS / 45000000) * 100 }")

  # Detect rate-limit signals across ALL transcripts
  multi_rate_limited="false"
  all_paths=("$TRANSCRIPT_PATH" "${AGENT_JSONL_PATHS[@]}")
  for path in "${all_paths[@]}"; do
    if [[ -f "$path" ]]; then
      rl_count=$(grep -c '"rate_limit"\|"429"\|"Rate limit"' "$path" 2>/dev/null || true)
      if [[ "$rl_count" -gt 0 ]]; then
        multi_rate_limited="true"
        break
      fi
    fi
  done

  multi_zone=$(calculate_zone "$multi_estimated_pct" "null" "null" "$multi_rate_limited")

  jq -n \
    --arg zone "$multi_zone" \
    --argjson five_pct "$multi_estimated_pct" \
    --argjson agent_count "$AGENT_COUNT" \
    --argjson total_tokens "$TOTAL_MULTI_TOKENS" \
    '{
      zone: $zone,
      five_hour_pct: $five_pct,
      seven_day_pct: null,
      resets_at: null,
      resets_in_min: null,
      is_using_overage: null,
      agent_count: $agent_count,
      total_tokens: $total_tokens,
      source: "multi-session"
    }'
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback path — parse JSONL transcript
# ---------------------------------------------------------------------------

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  emit_unknown
  exit 0
fi

# Sum output_tokens across all assistant messages in the transcript
total_output_tokens=$(
  grep '"type":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -r '.message.usage.output_tokens // 0' 2>/dev/null \
    | awk '{sum+=$1} END {print (sum ? sum : 0)}'
)

# Estimate five-hour percentage (45,000,000 output tokens = 100%)
# Use awk for float arithmetic since bash only does integers
estimated_pct=$(awk "BEGIN { printf \"%.4f\", ($total_output_tokens / 45000000) * 100 }")

# Detect rate-limit signals (429 / rate_limit strings in transcript)
rate_limit_count=$(grep -c '"rate_limit"\|"429"\|"Rate limit"' "$TRANSCRIPT_PATH" 2>/dev/null || true)
rate_limited="false"
if [[ "$rate_limit_count" -gt 0 ]]; then
  rate_limited="true"
fi

zone=$(calculate_zone "$estimated_pct" "null" "null" "$rate_limited")

jq -n \
  --arg zone "$zone" \
  --argjson five_pct "$estimated_pct" \
  '{
    zone: $zone,
    five_hour_pct: $five_pct,
    seven_day_pct: null,
    resets_at: null,
    resets_in_min: null,
    is_using_overage: null,
    source: "jsonl"
  }'
