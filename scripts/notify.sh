#!/usr/bin/env bash
# notify.sh — Marathon Mode notification dispatcher
#
# Reads notification config from .claude/marathon-config.local.md YAML frontmatter
# and dispatches a notification via the configured method.
#
# Usage: notify.sh [title] [message] [cwd]
#   $1 = title    (default: "Marathon Mode")
#   $2 = message  (required for meaningful output, but won't error if empty)
#   $3 = cwd      (optional; used to locate the config file)

set -euo pipefail

TITLE="${1:-Marathon Mode}"
MESSAGE="${2:-}"
CWD="${3:-$(pwd)}"

CONFIG_FILE="${CWD}/.claude/marathon-config.local.md"

# Config is optional — exit silently if it doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
  exit 0
fi

# Extract YAML frontmatter (content between the first pair of --- delimiters)
# and parse notification_type and notification_url values.
FRONTMATTER="$(awk '/^---/{if(found) exit; found=1; next} found{print}' "$CONFIG_FILE")"

# Parse a single key from the frontmatter: key: value (strips surrounding whitespace)
_parse_key() {
  local key="$1"
  echo "$FRONTMATTER" | grep -E "^[[:space:]]*${key}[[:space:]]*:" | head -n1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" \
    | sed -E "s/[[:space:]]*$//" \
    | sed -E "s/^['\"]|['\"]$//g"
}

NOTIFICATION_TYPE="$(_parse_key "notification_type")"
NOTIFICATION_URL="$(_parse_key "notification_url")"

# Nothing configured — exit silently
if [[ -z "$NOTIFICATION_TYPE" || "$NOTIFICATION_TYPE" == "none" ]]; then
  exit 0
fi

case "$NOTIFICATION_TYPE" in
  ntfy)
    # POST message body to the ntfy URL with a Title header
    if [[ -z "$NOTIFICATION_URL" ]]; then
      exit 0
    fi
    curl -s -X POST "$NOTIFICATION_URL" \
      -H "Title: ${TITLE}" \
      -d "${MESSAGE}" || true
    ;;

  webhook)
    # POST JSON {"title":"...","message":"..."} to the webhook URL
    if [[ -z "$NOTIFICATION_URL" ]]; then
      exit 0
    fi
    if command -v jq &>/dev/null; then
      # Use jq for safe JSON construction (handles special characters)
      PAYLOAD="$(jq -n --arg title "$TITLE" --arg message "$MESSAGE" \
        '{"title": $title, "message": $message}')"
      curl -s -X POST "$NOTIFICATION_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" || true
    else
      # Fallback: basic JSON without jq (safe for simple strings without quotes/backslashes)
      curl -s -X POST "$NOTIFICATION_URL" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"${TITLE}\",\"message\":\"${MESSAGE}\"}" || true
    fi
    ;;

  osascript)
    # macOS native notification via osascript
    if command -v osascript &>/dev/null; then
      osascript -e "display notification \"${MESSAGE}\" with title \"${TITLE}\"" || true
    fi
    ;;

  none|"")
    # Explicitly silenced — do nothing
    exit 0
    ;;

  *)
    # Unknown type — exit silently rather than breaking the caller
    exit 0
    ;;
esac
