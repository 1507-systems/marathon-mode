---
description: "Show current marathon state and quota"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", "Read"]
---

# /marathon-status — Check Marathon State

Show the current marathon session state and quota information.

## Steps

1. **Check if active:** Read `.claude/marathon.local.md`. If it doesn't exist, say "No marathon active." and stop.

2. **Read state file:** Parse the YAML frontmatter to extract: mode, current_task, total_tasks, quota_zone, started_at, wake_time, tasks_file.

3. **Get live quota:** Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/quota-check.sh" "{session_id}" "{transcript_path_if_known}"
   ```
   Parse the JSON output for zone, five_hour_pct, seven_day_pct, resets_in_min, source.

   If quota-check.sh fails or returns unknown, show "Quota: unknown (StatusLine not configured)" instead.

4. **Read task file:** Count lines matching `- [x]` (completed), `- [ ]` (remaining), and any marked `[FAILED]` or `[WIP]`.

5. **Get current task description:** Find the {current_task}th unchecked `- [ ]` line and extract its description.

6. **Calculate durations:**
   - Session duration from started_at to now
   - Time to wake_time (if set)

7. **Display:**

```
Marathon Active | {Mode} Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Task:     {current}/{total} — "{current task description}"
Model:    {from model hint or "auto"}
Zone:     {ZONE} ({pct}% used)
Resets:   {time} ({source})
Wake:     {time or "not set"} ({duration remaining})
Duration: {session duration}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Completed: {n} | Remaining: {n} | Failed: {n} | WIP: {n}
```
