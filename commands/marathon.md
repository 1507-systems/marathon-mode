---
description: "Start a marathon session — quota-aware autonomous work"
argument-hint: "[--file path] [--orchestrate] [--wake-time HH:MM]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", "Read", "Write", "Edit", "Glob", "Grep", "Agent"]
---

# /marathon — Start a Marathon Session

You are starting a quota-aware autonomous work session.

## Pre-Flight Checks

1. **Check for existing session:** Read `.claude/marathon.local.md`. If it exists and has `active: true`, show its status and ask: "A marathon is already active. Run `/marathon-stop` first, or `/marathon-status` to check progress."

2. **Parse arguments** from `$ARGUMENTS`:
   - `--file <path>`: Path to task file (default: `.claude/marathon-tasks.md`)
   - `--orchestrate`: Enable autonomous task dispatch mode (default: advisory)
   - `--wake-time HH:MM`: Time to stop and wind down (optional, for overnight runs)

3. **Locate task file:**
   - If `--file` provided, verify it exists
   - Otherwise check `.claude/marathon-tasks.md`
   - If neither exists: "No task file found. Run `/marathon-tasks` to build one, or provide `--file path`."

4. **Check for resume marker:** Look for `<!-- resume_after: ... -->` in the task file. If present and the timestamp has passed, announce: "Resuming from previous session. Picking up at the first incomplete task."

5. **Validate task file:** Parse it — count total tasks (lines matching `- [ ]`), verify format looks correct.

6. **Check jq dependency:** Run `command -v jq`. If missing, warn: "jq is required for accurate quota monitoring. Install with `brew install jq` (macOS) or `apt install jq` (Linux)."

## Setup

7. **Create state file** at `.claude/marathon.local.md`:

```
---
active: true
mode: {advisory or orchestrate}
session_id: "{from environment or generate}"
started_at: "{current UTC ISO timestamp}"
wake_time: "{from --wake-time or null}"
current_task: 1
total_tasks: {count}
quota_zone: green
last_check_pct: 0
last_check_at: "{current UTC ISO timestamp}"
resets_at: 0
tasks_file: "{path to task file}"
---
```

Use `$CLAUDE_CODE_SESSION_ID` environment variable for session_id if available, otherwise generate one.

8. **StatusLine check:** Check if the user has a statusLine configured in `~/.claude/settings.json`. If not, show:
   > "For accurate quota monitoring, I recommend adding the marathon StatusLine. Add this to your `~/.claude/settings.json`:
   > ```json
   > {"statusLine": {"type": "command", "command": "{absolute path to scripts/statusline-quota.sh}"}}
   > ```
   > This shows live quota percentage and zone in your terminal. Want me to add it?"

   If they agree, update settings.json.

9. **Send notification:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" "Marathon Started" "{total_tasks} tasks, mode: {mode}" "$(pwd)"
   ```

## Mode-Specific Behavior

### Advisory Mode (default)
Print a summary:
```
Marathon Active | Advisory Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Tasks: {n} loaded from {file}
Mode:  Advisory (quota monitoring active, you drive)
Wake:  {time or "not set"}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
The quota monitor is now active. You'll see zone
transitions (GREEN/YELLOW/ORANGE/RED) as systemMessages.
Work normally — I'll warn you when to wind down.
```

### Orchestrate Mode (--orchestrate)
Announce: "Starting orchestrated execution. Reading the orchestrate skill for dispatch logic."

Then read and follow the skill at `${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`. The skill handles task dispatch, model selection, and discipline enforcement.
