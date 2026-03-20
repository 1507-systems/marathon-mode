#!/usr/bin/env bash
# generate-schedule.sh — Generate platform-native scheduler configs for marathon-mode.
# Reads templates from ../templates/ relative to this script's location and performs
# token substitution to produce launchd plists, crontab lines, or systemd units.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"

# ── Defaults ──────────────────────────────────────────────────────────────────
PLATFORM=""
START_TIME="22:00"
STOP_TIME="07:30"
WORKING_DIR="$(pwd)"
TASKS_FILE=".claude/marathon-tasks.md"
UNINSTALL=false
INSTALL=false
DAYS="*"  # cron day-of-week field; * = daily

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --platform macos|linux|cron   Target platform (required unless --uninstall)
  --start    HH:MM              Session start time (default: 22:00)
  --stop     HH:MM              Wake/wind-down time (default: 07:30)
  --working-dir PATH            Working directory for claude invocation (default: cwd)
  --tasks-file PATH             Path to tasks file (default: .claude/marathon-tasks.md)
  --days     DAYS               Cron day-of-week field (default: * for daily)
  --install                     Write config to system location and load it
  --uninstall                   Remove config from system location and unload it
EOF
    exit 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)    PLATFORM="$2";     shift 2 ;;
        --start)       START_TIME="$2";   shift 2 ;;
        --stop)        STOP_TIME="$2";    shift 2 ;;
        --working-dir) WORKING_DIR="$2";  shift 2 ;;
        --tasks-file)  TASKS_FILE="$2";   shift 2 ;;
        --days)        DAYS="$2";         shift 2 ;;
        --install)     INSTALL=true;      shift   ;;
        --uninstall)   UNINSTALL=true;    shift   ;;
        -h|--help)     usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# ── Uninstall path ────────────────────────────────────────────────────────────
if [[ "$UNINSTALL" == true ]]; then
    case "${PLATFORM:-$(uname -s)}" in
        macos|Darwin)
            PLIST="$HOME/Library/LaunchAgents/com.marathon-mode.nightly.plist"
            if [[ -f "$PLIST" ]]; then
                launchctl unload "$PLIST" 2>/dev/null || true
                mv "$PLIST" ~/.Trash/
                echo "Removed launchd plist and unloaded service."
            else
                echo "No launchd plist found at ${PLIST}."
            fi
            ;;
        linux|Linux)
            TIMER="$HOME/.config/systemd/user/marathon-mode.timer"
            SERVICE="$HOME/.config/systemd/user/marathon-mode.service"
            systemctl --user disable --now marathon-mode.timer 2>/dev/null || true
            [[ -f "$TIMER" ]]   && mv "$TIMER"   ~/.Trash/
            [[ -f "$SERVICE" ]] && mv "$SERVICE" ~/.Trash/
            systemctl --user daemon-reload
            echo "Removed systemd timer and service."
            ;;
        cron)
            # Remove the marathon-mode crontab line
            crontab -l 2>/dev/null | grep -v 'marathon-mode' | crontab -
            echo "Removed marathon-mode crontab entry."
            ;;
        *)
            echo "Unknown platform for uninstall: ${PLATFORM}" >&2
            exit 1
            ;;
    esac
    exit 0
fi

# ── Require platform for non-uninstall paths ──────────────────────────────────
if [[ -z "$PLATFORM" ]]; then
    echo "Error: --platform is required." >&2
    usage
fi

# ── Resolve claude binary ─────────────────────────────────────────────────────
CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
if [[ -z "$CLAUDE_PATH" ]]; then
    echo "Error: 'claude' binary not found in PATH." >&2
    exit 1
fi

# ── Parse times ───────────────────────────────────────────────────────────────
START_HOUR="${START_TIME%%:*}"
START_MINUTE="${START_TIME##*:}"
# Strip leading zeros to avoid octal interpretation issues
START_HOUR="${START_HOUR#0}"
START_MINUTE="${START_MINUTE#0}"
# Default to 0 when the field is empty (e.g. time was "X:00")
START_HOUR="${START_HOUR:-0}"
START_MINUTE="${START_MINUTE:-0}"

WAKE_TIME="$STOP_TIME"

# ── sed substitution helper ───────────────────────────────────────────────────
# Usage: apply_substitutions <template_content>
# Reads from stdin, writes substituted content to stdout.
apply_substitutions() {
    sed \
        -e "s|__START_HOUR__|${START_HOUR}|g" \
        -e "s|__START_MINUTE__|${START_MINUTE}|g" \
        -e "s|__WAKE_TIME__|${WAKE_TIME}|g" \
        -e "s|__WORKING_DIR__|${WORKING_DIR}|g" \
        -e "s|__TASKS_FILE__|${TASKS_FILE}|g" \
        -e "s|__CLAUDE_PATH__|${CLAUDE_PATH}|g" \
        -e "s|__MINUTE__|${START_MINUTE}|g" \
        -e "s|__HOUR__|${START_HOUR}|g" \
        -e "s|__DAYS__|${DAYS}|g"
}

# ── Platform handlers ─────────────────────────────────────────────────────────

generate_macos() {
    local template="${TEMPLATES_DIR}/launchd.plist.template"
    if [[ ! -f "$template" ]]; then
        echo "Error: template not found: ${template}" >&2
        exit 1
    fi

    local output
    output="$(apply_substitutions < "$template")"

    if [[ "$INSTALL" == true ]]; then
        local plist_path="$HOME/Library/LaunchAgents/com.marathon-mode.nightly.plist"
        mkdir -p "$HOME/Library/LaunchAgents"
        echo "$output" > "$plist_path"
        chmod 644 "$plist_path"
        # Unload first in case it's already loaded, ignore errors
        launchctl unload "$plist_path" 2>/dev/null || true
        launchctl load "$plist_path"
        echo "Installed and loaded: ${plist_path}"
    else
        echo "$output"
    fi
}

generate_cron() {
    local template="${TEMPLATES_DIR}/cron.template"
    if [[ ! -f "$template" ]]; then
        echo "Error: template not found: ${template}" >&2
        exit 1
    fi

    local cron_line
    cron_line="$(apply_substitutions < "$template")"

    if [[ "$INSTALL" == true ]]; then
        # Append to crontab, avoiding duplicates
        local existing
        existing="$(crontab -l 2>/dev/null || true)"
        if echo "$existing" | grep -q 'marathon-mode'; then
            echo "Warning: existing marathon-mode crontab entry found. Remove it first with --uninstall." >&2
            exit 1
        fi
        (echo "$existing"; echo "$cron_line") | crontab -
        echo "Installed crontab entry."
    else
        echo "$cron_line"
    fi
}

generate_linux() {
    local template="${TEMPLATES_DIR}/systemd.template"
    if [[ ! -f "$template" ]]; then
        echo "Error: template not found: ${template}" >&2
        exit 1
    fi

    local full_template
    full_template="$(apply_substitutions < "$template")"

    # Split on ---SERVICE--- separator
    local timer_content service_content
    timer_content="$(echo "$full_template" | sed '/^---SERVICE---$/,$d')"
    service_content="$(echo "$full_template" | sed '1,/^---SERVICE---$/d')"

    if [[ "$INSTALL" == true ]]; then
        local systemd_dir="$HOME/.config/systemd/user"
        mkdir -p "$systemd_dir"

        echo "$timer_content" > "${systemd_dir}/marathon-mode.timer"
        echo "$service_content" > "${systemd_dir}/marathon-mode.service"

        systemctl --user daemon-reload
        systemctl --user enable --now marathon-mode.timer
        echo "Installed and enabled systemd timer and service."
    else
        echo "=== marathon-mode.timer ==="
        echo "$timer_content"
        echo ""
        echo "=== marathon-mode.service ==="
        echo "$service_content"
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$PLATFORM" in
    macos)  generate_macos ;;
    linux)  generate_linux ;;
    cron)   generate_cron  ;;
    *)
        echo "Error: unknown platform '${PLATFORM}'. Use: macos, linux, cron." >&2
        exit 1
        ;;
esac
