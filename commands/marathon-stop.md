---
description: "Gracefully stop the current marathon session"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", "Read", "Write", "Edit"]
---

# /marathon-stop — Graceful Wind-Down

Execute the marathon wind-down sequence. This is the same sequence triggered automatically by ORANGE zone, but user-initiated.

## Steps

1. **Check if active:** Read `.claude/marathon.local.md`. If not active, say "No marathon active." and stop.

2. **If mid-task** (subagent running or work uncommitted):
   - Check `git status` for uncommitted changes
   - If dirty: `git add -A && git commit -m "WIP: marathon task {current_task} — {description}"`

3. **Update task file** (`.claude/marathon-tasks.md` or path from state):
   - Completed tasks should already be checked `- [x]`
   - Mark current incomplete task as `- [WIP]` if it was in progress
   - Leave remaining tasks as `- [ ]`

4. **Update PROJECT_LOGs:** For each project that had tasks completed during this marathon, verify its PROJECT_LOG.md was updated. If not, add a brief entry noting what was done.

5. **Push:** Run `git push` for all repos that have unpushed commits.

6. **Notify:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" "Marathon Stopped" "{completed}/{total} tasks done, {remaining} remaining" "$(pwd)"
   ```

7. **Clean up:**
   - Remove `.claude/marathon.local.md`
   - Remove `/tmp/marathon-quota-{session_id}.json` if it exists

8. **Display summary:**
```
Marathon Stopped
━━━━━━━━━━━━━━━
Completed: {n}/{total}
Failed:    {n}
WIP:       {n}
Remaining: {n}
Duration:  {time}
━━━━━━━━━━━━━━━
Task file preserved at {path} — run /marathon to resume.
```
