---
description: "Quota-aware autonomous work sessions — start, tasks, status, stop, schedule"
argument-hint: "[tasks|status|stop|schedule] [--orchestrate] [--dry-run] [--wake-time HH:MM] [--file path] [--scan] [--source path]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Glob, Grep, Agent
---

# /marathon — Quota-Aware Work Sessions

Parse `$ARGUMENTS` to determine which subcommand to run. The first positional argument (if it matches a subcommand name) selects the mode. If no subcommand is given, default to **start**.

| Input | Action |
|-------|--------|
| `/marathon` | Start advisory session |
| `/marathon --orchestrate` | Start orchestrate session |
| `/marathon --orchestrate --dry-run` | Show dispatch plan without running |
| `/marathon --orchestrate --wake-time 07:30` | Overnight autonomous run |
| `/marathon --file ./tasks.md` | Start with specific task file |
| `/marathon tasks` | Build task list interactively |
| `/marathon tasks --scan` | Scan repos for TODOs/dirty state |
| `/marathon tasks --source file` | Extract tasks from a projects file |
| `/marathon status` | Show session state + quota |
| `/marathon stop` | Graceful wind-down |
| `/marathon schedule` | Set up nightly launchd automation |
| `/marathon schedule --uninstall` | Remove scheduler config |

---

## Subcommand: start (default)

You are starting a quota-aware autonomous work session.

### Pre-Flight Checks

1. **Check for existing session:** Read `.claude/marathon.local.md`. If it exists and has `active: true`, show its status and ask: "A marathon is already active. Run `/marathon stop` first, or `/marathon status` to check progress."

2. **Parse arguments** from `$ARGUMENTS`:
   - `--file <path>`: Path to task file (default: `.claude/marathon-tasks.md`)
   - `--orchestrate`: Enable autonomous task dispatch mode (default: advisory)
   - `--dry-run`: Parse the task file and show what would be dispatched, then exit. No agents are dispatched, no state file is created. Only valid with `--orchestrate`.
   - `--wake-time HH:MM`: Time to stop and wind down (optional, for overnight runs)

3. **Locate task file:**
   - If `--file` provided, verify it exists
   - Otherwise check `.claude/marathon-tasks.md`
   - If neither exists: "No task file found. Run `/marathon tasks` to build one, or provide `--file path`."

4. **Check for resume marker:** Look for `<!-- resume_after: ... -->` in the task file. If present and the timestamp has passed, announce: "Resuming from previous session. Picking up at the first incomplete task."

5. **Validate task file:** Parse it — count total tasks (lines matching `- [ ]`), verify format looks correct.

6. **Keychain pre-unlock:** Attempt to unlock the login keychain:
   ```bash
   security unlock-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null
   KEYCHAIN_UNLOCKED=$?
   ```
   If `KEYCHAIN_UNLOCKED != 0` (headless session, keychain locked):
   - Log warning: "Keychain is locked (headless session). Credential-dependent tasks will be tagged as blocked."
   - Scan the task file for tasks whose descriptions match credential-dependent keywords:
     - "deploy", "Cloudflare", "CF", "Home Assistant", "HA", "Zoho", "API key", "API token", "secret", "credential", "wrangler", "publish", "authenticate"
   - For each matching task that doesn't already have a `<!-- blocked: -->` annotation, append `<!-- blocked: keychain -->` on the line after the task.
   - Report: "N tasks blocked (keychain locked)."

7. **Check jq dependency:** Run `command -v jq`. If missing, warn: "jq is required for accurate quota monitoring. Install with `brew install jq` (macOS) or `apt install jq` (Linux)."

### Setup

8. **Create state file** at `.claude/marathon.local.md`:

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
watchdog_pid: null
keychain_unlocked: {true or false}
---
```

Use `$CLAUDE_CODE_SESSION_ID` environment variable for session_id if available, otherwise generate one.

9. **StatusLine check:** Check if the user has a statusLine configured in `~/.claude/settings.json`. If not, show:
   > "For accurate quota monitoring, I recommend adding the marathon StatusLine. Add this to your `~/.claude/settings.json`:
   > ```json
   > {"statusLine": {"type": "command", "command": "{absolute path to scripts/statusline-quota.sh}"}}
   > ```
   > This shows live quota percentage and zone in your terminal. Want me to add it?"

   If they agree, update settings.json.

10. **Send notification:**
    ```bash
    "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" "Marathon Started" "{total_tasks} tasks, mode: {mode}" "$(pwd)"
    ```

### Mode-Specific Behavior

#### Advisory Mode (default)
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

#### Orchestrate Mode (--orchestrate)
Announce: "Starting orchestrated execution. Reading the orchestrate skill for dispatch logic."

Then read and follow the skill at `${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`. The skill handles task dispatch, model selection, and discipline enforcement.

#### Dry-Run Mode (--orchestrate --dry-run)

When `--dry-run` is passed alongside `--orchestrate`:

1. **Parse the task file** and build the full dependency graph exactly as described in the orchestrate skill (Sections 1 and 2). Do NOT create a state file.

2. **Classify every task:**
   - **Dispatchable**: pending (`- [ ]`), no unmet dependencies, no `<!-- requires: -->`, no `<!-- blocked: keychain -->`.
   - **Blocked (manual)**: has `<!-- requires: hardware|gui|verve -->`.
   - **Blocked (keychain)**: has `<!-- blocked: keychain -->`.
   - **Blocked (dependencies)**: has unmet `<!-- after: X -->` dependencies (X is not yet `[x]` or `[FAILED]`).

3. **Determine model for each dispatchable task** using the complexity assessment rules from the orchestrate skill Section 3 (no quota downshift — dry-run assumes GREEN zone).

4. **Build the dispatch tiers** — simulate the eligibility loop to determine which tasks would be dispatched first (tier 1 = tasks eligible immediately), and which would become eligible after tier 1 completes (tier 2), and so on. Use the same eligibility rules as the real dispatch loop.

5. **Print the dry-run report:**

```
Marathon Dry Run
━━━━━━━━━━━━━━━
Dispatchable: N tasks
Blocked (manual): N tasks
Blocked (keychain): N tasks
Blocked (dependencies): N tasks

Dispatch order (by eligibility):
1. [haiku] Task description (project-name)
2. [sonnet] Task description (project-name)
...

After tier 1 completes, newly eligible:
N. [sonnet] Task description (project-name)
...

(Repeat for further tiers if applicable)
```

   - If there are blocked tasks, list them at the end with their blocking reason.
   - Do NOT dispatch any agents.
   - Do NOT create `.claude/marathon.local.md`.
   - Exit after printing the report.

---

## Subcommand: tasks

Generate a prioritized task list for marathon execution. The output is always a markdown checklist at `.claude/marathon-tasks.md` (or a user-specified path).

### Modes

#### `--scan` — Scan Working Directory

Scan all projects in the current working directory for actionable work:

1. **Find git repos:** `find . -name .git -type d -maxdepth 3`
2. **For each repo, check:**
   - `git status --porcelain` — dirty working tree? → "Commit/push pending changes in {project}"
   - `git log @{u}..HEAD --oneline 2>/dev/null` — unpushed commits? → "Push {n} commits in {project}"
   - `git branch --merged main | grep -v main` — stale branches? → "Clean up merged branches in {project}"
3. **Parse PROJECT_LOG.md files:** Look for "Next Steps" or "TODO" sections, extract items
4. **Code scan:** `grep -rn 'TODO\|FIXME\|HACK\|XXX' --include='*.ts' --include='*.js' --include='*.py' --include='*.sh'` — group by project
5. **Prioritize:**
   - Priority 1 (Critical): Broken tests, security issues, blocking bugs
   - Priority 2 (High): Pending features, incomplete implementations
   - Priority 3 (Normal): Doc updates, git housekeeping, code TODOs
   - Priority 4 (If Time): Nice-to-haves, cleanup
6. **Auto-assign model hints:**
   - `<!-- model: haiku -->` for git housekeeping, doc updates, pushing commits
   - `<!-- model: sonnet -->` for tests, straightforward fixes, deployments
   - `<!-- model: opus -->` for new features, refactors, security audits

#### `--source <path>` — Parse a Projects File

Read a structured projects file (like a `projects.md`) and extract actionable items:

1. Parse project entries — look for status indicators (pending, needs, TODO, known issues)
2. Extract actionable items from each project's description
3. Prioritize based on status severity
4. Auto-assign model hints based on task complexity
5. Group by project with dependency hints (`<!-- after: ... -->` for same-project sequential tasks)

#### No Arguments — Interactive

1. Ask: "What would you like to work on? I can help prioritize and build a task list."
2. Have a conversation to understand priorities
3. Build the list collaboratively

### Output Format

Write to `.claude/marathon-tasks.md`:

```markdown
# Marathon Tasks

Generated: {UTC ISO timestamp}
Source: {scan|source file|interactive}

## Priority 1 (Critical)
- [ ] {task description}
  <!-- model: opus -->

## Priority 2 (High)
- [ ] {task description}
- [ ] {task description}
  <!-- after: {previous task} -->

## Priority 3 (Normal)
- [ ] {task description}
  <!-- model: haiku -->

## Priority 4 (If Time Permits)
- [ ] {task description}
```

### Post-Generation: Manual Task Detection

After building the task list (regardless of mode — scan, source, or interactive), run a keyword scan to detect tasks requiring manual/physical interaction:

| Signal Keywords | Tag |
|----------------|-----|
| "dashboard", "console", "portal", "UI config", "GUI" | `<!-- requires: gui -->` |
| "Xcode", "App Store Connect", "TestFlight", "Simulator" | `<!-- requires: verve -->` |
| "UniFi", "router", "switch config", "VLAN" | `<!-- requires: gui -->` |
| "hardware", "physical", "plug in", "cable", "install device", "swap", "flash" | `<!-- requires: hardware -->` |
| "manually", "by hand", "sign in to", "log in to" | `<!-- requires: gui -->` |
| "Verve", "desktop app" | `<!-- requires: verve -->` |
| "screenshots", "screen recording" | `<!-- requires: gui -->` |

For each matching `- [ ]` task:
1. Append the appropriate `<!-- requires: ... -->` annotation on the line after the task.
2. In interactive mode: highlight these tasks and ask "These tasks appear to require manual interaction. Include them for dispatch, or mark as manual-only?"
3. In non-interactive mode (--scan, --source): auto-tag silently and note in the output: "N tasks tagged as manual-only (won't be dispatched by orchestrator)."

### After Generation

Always present the generated list to the user:
- Show the full task list
- Ask: "Does this look right? You can edit the file directly or tell me what to change. When ready, run `/marathon` to start."

---

## Subcommand: status

Show the current marathon session state and quota information.

### Steps

1. **Check if active:** Read `.claude/marathon.local.md`. If it doesn't exist, say "No marathon active." and stop.

2. **Read state file:** Parse the YAML frontmatter to extract: mode, current_task, total_tasks, quota_zone, started_at, wake_time, tasks_file.

3. **Get live quota:** Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/quota-check.sh" "{session_id}" "{transcript_path_if_known}"
   ```
   Parse the JSON output for zone, five_hour_pct, seven_day_pct, resets_in_min, source.

   If quota-check.sh fails or returns unknown, show "Quota: unknown (StatusLine not configured)" instead.

4. **Read task file:** Count lines matching `- [x]` (completed), `- [ ]` (remaining), and any marked `[FAILED]`, `[WIP]`, `<!-- requires: -->` (manual), or `<!-- blocked: keychain -->` (keychain-blocked).

5. **Get current task description:** Find the {current_task}th unchecked `- [ ]` line and extract its description.

5a. **Get agent info:** If `/tmp/marathon-agents-{session_id}.json` exists, count active agents and check for stall log entries at `/tmp/marathon-stall-log-{session_id}.jsonl`.

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
Agents:   {n} active | {n} stalls detected
Keychain: {unlocked or locked}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Completed: {n} | Remaining: {n} | Failed: {n} | WIP: {n} | Manual: {n} | Keychain: {n}
```

---

## Subcommand: stop

Execute the marathon wind-down sequence. This is the same sequence triggered automatically by ORANGE zone, but user-initiated.

### Steps

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

7. **Kill watchdog:** If `watchdog_pid` is set in the state file and not null, send SIGTERM:
   ```bash
   kill "$WATCHDOG_PID" 2>/dev/null || true
   ```

8. **Clean up:**
   - Remove `.claude/marathon.local.md`
   - Remove `/tmp/marathon-quota-{session_id}.json` if it exists
   - Remove `/tmp/marathon-agents-{session_id}.json` if it exists
   - Remove `/tmp/marathon-stall-log-{session_id}.jsonl` if it exists

9. **Display summary:**
```
Marathon Stopped
━━━━━━━━━━━━━━━
Completed:        {n}/{total}
Failed:           {n}
Stalled+Retried:  {n} (from stall log)
WIP:              {n}
Skipped (manual): {n}
Skipped (keychain): {n}
Remaining:        {n}
Duration:         {time}
━━━━━━━━━━━━━━━
Task file preserved at {path} — run /marathon to resume.
```

---

## Subcommand: schedule

Generate platform-native scheduler configs for automated marathon sessions.

### Steps

1. **Parse arguments** from `$ARGUMENTS`:
   - `--platform`: auto (detect), macos, linux, cron
   - `--start HH:MM`: When to start (default: 22:00)
   - `--stop HH:MM`: Wake time / when to wind down (default: 07:30)
   - `--days`: weekdays, daily, or custom cron expression (default: daily)
   - `--regenerate`: Update existing config with new settings
   - `--uninstall`: Remove scheduler config

2. **Read existing config** from `.claude/marathon-config.local.md` if it exists — use saved defaults.

3. **Auto-detect platform** if `--platform auto`:
   - macOS: `uname -s` == "Darwin"
   - Linux: check for systemd (`systemctl --version`)
   - Fallback: cron

4. **For `--uninstall`:** Call generate-schedule.sh with --uninstall flag.

5. **Generate config:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/generate-schedule.sh" \
     --platform {platform} \
     --start {start} \
     --stop {stop} \
     --working-dir "$(pwd)" \
     --tasks-file ".claude/marathon-tasks.md"
   ```

6. **Show the generated config** to the user. Ask: "Install this config? (This will run marathon automatically at {start} every {days})"

7. **If user agrees:** Install the config (re-run with appropriate install commands).

8. **Save settings** to `.claude/marathon-config.local.md`:
   ```markdown
   ---
   notification_type: {existing or ask}
   notification_url: "{existing or ask}"
   default_mode: orchestrate
   default_wake_buffer_min: 30
   schedule_platform: {platform}
   schedule_start: "{start}"
   schedule_stop: "{stop}"
   schedule_days: {days}
   ---
   ```

9. **Show verification:** How to check it's working (e.g., `launchctl list | grep marathon` for macOS).
