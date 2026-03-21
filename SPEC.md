# Marathon Mode — Design Specification

**Date:** 2026-03-20
**Status:** Draft
**License:** MIT
**Repo:** `1507-systems/marathon-mode` (public)

## Overview

Marathon Mode is a Claude Code plugin that enables quota-aware autonomous work sessions. It monitors real-time API rate limits, right-sizes model selection per task, manages parallel dispatch with quota-throttled concurrency, and ensures clean breakpoints before quota exhaustion.

It operates in two modes:
- **Advisory** (default): Monitors quota and injects guidance. The user drives the session.
- **Orchestrate** (`--orchestrate`): Fully autonomous task dispatch with subagent parallelism, model selection, doc discipline, and graceful wind-down.

Marathon composes with existing tools — Ralph Loop for iterative sub-tasks within a marathon, superpowers skills for development workflows, any MCP server the user has configured.

## Problem Statement

Claude Code sessions have finite quota (5-hour rolling window, 7-day weekly cap). Long autonomous sessions — overnight batch work, multi-project sweeps — fail unpredictably when they hit limits mid-task. This causes:

- Half-finished work with no commit
- Stale documentation (PROJECT_LOGs not updated)
- No notification to the user
- No way to resume cleanly
- Wasted quota on tasks that don't need expensive models

Marathon Mode solves all of these by making quota a first-class concern in autonomous workflows.

## Architecture

### Plugin Structure

```
marathon-mode/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── commands/
│   ├── marathon.md              # Start a marathon session
│   ├── marathon-status.md       # Check current state + quota
│   ├── marathon-stop.md         # Graceful wind-down
│   ├── marathon-schedule.md     # Generate/install scheduler configs
│   └── marathon-tasks.md        # Build a task list from project state
├── hooks/
│   ├── hooks.json               # Hook registration (PostToolUse, Stop)
│   ├── quota-monitor.sh         # PostToolUse hook — quota tracking
│   └── stop-hook.sh             # Stop hook — task cycling in orchestrate mode
├── skills/
│   └── orchestrate/
│       └── SKILL.md             # Orchestration skill — task dispatch + model selection
├── scripts/
│   ├── quota-check.sh           # Read quota state, output JSON summary
│   ├── statusline-quota.sh      # StatusLine integration (display-only, optional)
│   ├── generate-schedule.sh     # Generate launchd/cron/systemd configs
│   └── notify.sh                # Notification dispatcher
├── templates/
│   ├── launchd.plist.template   # macOS launchd template
│   ├── cron.template            # Cron entry template
│   └── systemd.template         # Linux systemd timer/service template
├── LICENSE                      # MIT
└── README.md
```

### Plugin Manifest: `.claude-plugin/plugin.json`

```json
{
  "name": "marathon-mode",
  "description": "Quota-aware autonomous work sessions for Claude Code. Real-time rate limit monitoring, per-task model right-sizing, parallel dispatch with throttled concurrency, and graceful wind-down.",
  "author": {
    "name": "1507 Systems",
    "url": "https://github.com/1507-systems/marathon-mode"
  }
}
```

### Hook Registration: `hooks/hooks.json`

```json
{
  "description": "Marathon Mode hooks for quota monitoring and task cycling",
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/quota-monitor.sh",
            "timeout": 10000
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

### Data Flow

There are two data paths depending on whether StatusLine is configured:

**Primary path (StatusLine configured — recommended):**

```
Claude Code API Response
  ↓ (rate limit headers → StatusLine JSON)
statusline-quota.sh (StatusLine command)
  ↓ (writes as side effect, then outputs display string)
/tmp/marathon-quota-{session_id}.json   ← quota data in /tmp (fast, no iCloud)
  ↓ (read by)
quota-monitor.sh (PostToolUse hook)
  ↓ (on zone change)
systemMessage injection → Claude sees quota guidance
```

The StatusLine script receives the full JSON (including `rate_limits.five_hour.used_percentage` and `resets_at`) on stdin. It writes a snapshot to `/tmp/` (avoiding iCloud sync latency on the working directory), then outputs the display string to stdout. This dual-purpose pattern is a side effect — the script writes first, then echoes.

**Fallback path (no StatusLine):**

```
Session JSONL file
  ↓ (parsed by)
quota-monitor.sh (PostToolUse hook)
  ↓ (extracts cumulative token counts from usage blocks)
Heuristic zone estimation
  ↓ (on zone change)
systemMessage injection
```

Without StatusLine, the hook reads the session JSONL (path from hook input `transcript_path`) and sums token usage across all messages. This provides cumulative token counts but NOT `used_percentage`, because:
- The server-side percentage accounts for all sessions, not just this one
- Token-to-percentage mapping depends on plan tier (unknown to the client)

**Fallback zone estimation without `used_percentage`:**
- Track cumulative output tokens (the primary quota cost)
- Use conservative thresholds based on known plan limits (Pro: ~45M tokens/5h estimated)
- Detect 429 responses in the JSONL as a hard RED signal
- Log a one-time warning recommending StatusLine configuration for accurate monitoring

The fallback is functional but significantly less precise. **StatusLine configuration is strongly recommended** and `/marathon` offers to set it up on first run.

## State Management

### Session State: `.claude/marathon.local.md`

Created when `/marathon` starts. Removed on clean completion. YAML frontmatter + markdown body, consistent with Ralph Loop's pattern.

```markdown
---
active: true
mode: orchestrate
session_id: "abc-123"
started_at: "2026-03-20T22:00:00Z"
wake_time: "2026-03-21T07:30:00Z"
current_task: 2
total_tasks: 8
quota_zone: green
last_check_pct: 42.3
last_check_at: "2026-03-20T23:15:00Z"
resets_at: 1742518800
tasks_file: ".claude/marathon-tasks.md"
---
```

### Persistent Config: `.claude/marathon-config.local.md`

Survives across sessions. Stores notification settings, schedule preferences, and user defaults.

```markdown
---
notification_type: ntfy
notification_url: "https://ntfy.sh/your-topic"
default_mode: orchestrate
default_wake_buffer_min: 30
schedule_platform: macos
schedule_start: "22:00"
schedule_stop: "07:30"
schedule_days: daily
---
```

### Quota Snapshot: `/tmp/marathon-quota-{session_id}.json`

Written by the StatusLine script on every StatusLine update. Stored in `/tmp/` for fast I/O (no iCloud sync). Read by the PostToolUse hook.

```json
{
  "five_hour": {
    "used_percentage": 42.3,
    "resets_at": 1742518800
  },
  "seven_day": {
    "used_percentage": 18.1,
    "resets_at": 1743033600
  },
  "is_using_overage": false,
  "overage_status": null,
  "updated_at": "2026-03-20T23:15:00Z"
}
```

### Task File: `.claude/marathon-tasks.md`

Prioritized checklist with optional model hints and dependency markers.

```markdown
# Marathon Tasks

Generated: 2026-03-20T22:00:00Z
Source: projects.md scan

## Priority 1 (Critical)
- [ ] Fix auth token refresh in login.ts — users getting 401 on valid tokens
  <!-- model: opus -->

## Priority 2 (High)
- [ ] Add vitest coverage for spirittrax scrapers — some returning 403/406
- [ ] Deploy browser-mcp Docker container on RogueNode
  <!-- after: Add vitest coverage -->

## Priority 3 (Normal)
- [ ] Update PROJECT_LOG.md for all projects touched since last audit
  <!-- model: haiku -->
- [ ] Push unpushed commits across all repos
  <!-- model: haiku -->
- [ ] Clean up stale branches in all repos
  <!-- model: haiku -->

## Priority 4 (If Time Permits)
- [ ] Noti App Store prep — screenshots, Connect listing
```

**Supported annotations:**
- `<!-- model: opus|sonnet|haiku -->` — Override automatic model selection
- `<!-- after: Task description prefix -->` — Dependency marker (must complete before this task starts)
- `<!-- independent -->` — Explicitly mark as safe to parallelize even within the same project

## Quota Monitoring

### Zone Definitions

Zones are calculated from `five_hour.used_percentage` (primary) with a weekly cap check as a guardrail.

| Zone | Trigger | Behavior |
|------|---------|----------|
| GREEN | < 70% five_hour AND < 90% seven_day | Full speed. Parallel subagents. Ideal model per task. |
| YELLOW | 70-85% five_hour OR > 90% seven_day | Finish current task. Max 2 parallel. Downshift opus→sonnet. |
| ORANGE | 85-95% five_hour | Wind-down mode. Commit, update docs, push. Downshift all models one tier. Sequential only. |
| RED | > 95% five_hour | Emergency save. Haiku only. Commit WIP, push, notify, prepare to stop. |
| COAST | > 95% five_hour AND resets_at < 45 min AND wake_time > 60 min away | Allow session to end cleanly. Scheduler restarts after reset. |

### Zone Transition Messages

The PostToolUse hook emits a `systemMessage` only when the zone changes (not on every tool call):

- **→ GREEN:** `"🟢 GREEN: Quota reset. Resuming full speed. {n} tasks remaining."`
- **→ YELLOW:** `"⚠️ YELLOW: {pct}% used, resets in {time}. Finish current task, then sequential only. Downshift complex tasks to Sonnet."`
- **→ ORANGE:** `"🟠 ORANGE: {pct}% used. Wind down: commit all work, update docs, push. Downshift all models one tier."`
- **→ RED:** `"🔴 RED: {pct}% used. Emergency save. Commit WIP, push, notify, stop."`
- **→ COAST:** `"🔵 COAST: {pct}% used, resets in {min}m. Saving state and exiting. Scheduler will restart session after reset."`

### Resume After Reset

COAST zone behavior (revised from initial design to avoid idle quota burn):

1. Complete current task if possible, or commit WIP
2. Update task file with progress — completed items checked, current task marked `[WIP]` if incomplete
3. Push all commits
4. Write resume state to task file header: `<!-- resume_after: {resets_at + 60s} -->`
5. Send notification: `"🔵 COAST: Pausing for quota reset. {n} tasks remaining. Will resume at {time}."`
6. Allow session to exit cleanly (Stop hook does NOT block)
7. The scheduler (launchd/cron/systemd) restarts the session after the reset time
8. On restart, `/marathon` detects existing task file with resume marker, picks up from the last incomplete task

This avoids burning tokens on an idle session. The scheduler handles the restart, and the task file is the persistence layer.

### Avoiding Hard Limits

The design aims to never hit an API 429 rejection. By starting wind-down at 85% (ORANGE) and exiting at 95% (COAST/RED), there's a buffer. If a 429 does occur, Claude Code's built-in retry-with-backoff handles it — the session doesn't die. The quota monitor will detect the rate limit via JSONL inspection and trigger RED zone.

## Model Selection

### Complexity Assessment

The orchestrator reads each task description and matches against heuristics:

| Complexity | Model | Task Signals |
|-----------|-------|-------------|
| Simple | Haiku | Doc/log updates, formatting, git housekeeping, find-and-replace, config edits, pushing commits, cleaning branches |
| Medium | Sonnet | Unit test writing, straightforward bug fixes, deployments, CI config, dependency updates |
| Complex | Opus | Multi-file refactors, new feature implementation, security audits, architecture decisions, complex debugging |

Model right-sizing happens regardless of quota pressure. A "push unpushed commits" task runs on Haiku even at 5% usage — there's no reason to burn Opus tokens on it. This means an overnight run gets 3-4x more tasks done because most tasks don't need the most expensive model.

### Quota Downshift

After complexity assessment, quota pressure applies an additional downshift:

```
final_model = downshift(ideal_model, quota_zone)

GREEN:   no change (use ideal model)
YELLOW:  opus → sonnet, rest unchanged
ORANGE:  opus → sonnet, sonnet → haiku
RED:     everything → haiku
```

User model hints (`<!-- model: opus -->`) override the complexity assessment but are still subject to quota downshift in ORANGE/RED zones.

## Parallel Dispatch

### Dependency Analysis

In orchestrate mode, the orchestrator groups tasks into dependency tiers:

```
Tier 1: [Task A, Task B, Task C]  ← independent, dispatch in parallel
Tier 2: [Task D]                  ← depends on Task A (via <!-- after: --> hint)
Tier 3: [Task E, Task F]          ← independent of each other, depend on Tier 2
```

**Independence heuristics:**
- Tasks in different projects are independent by default
- Tasks in the same project are sequential by default (unless marked `<!-- independent -->`)
- Explicit `<!-- after: ... -->` markers create hard dependencies

### Quota-Throttled Concurrency

| Zone | Max Parallel Subagents |
|------|----------------------|
| GREEN | All independent tasks in current tier |
| YELLOW | 2 |
| ORANGE | 1 (sequential) |
| RED | 0 (wind down) |

### Subagent Dispatch

Each task dispatched via the Agent tool with explicit model selection:

```
Agent(
  description: "Marathon task {n}/{total}",
  prompt: "{task description}\n\n{discipline rules}",
  model: "{final_model}"
)
```

The Agent tool supports a `model` parameter with values `"sonnet"`, `"opus"`, or `"haiku"`, enabling per-task model selection directly.

**Discipline rules injected into every subagent:**
- Commit your changes before finishing
- Update PROJECT_LOG.md with what you did
- Only work on this specific task — do not start other tasks
- If blocked, document the blocker and complete without resolving it

### Between Tasks

After each task completes:
1. Verify the subagent committed its work
2. Check off the task in marathon-tasks.md
3. Push commits
4. Send notification: `"✅ {n}/{total}: {task summary}"`
5. Re-check quota zone before dispatching next task/tier

## Commands

### `/marathon [--file path] [--orchestrate] [--wake-time HH:MM]`

Start a marathon session.

1. Refuse if marathon already active (check state file)
2. Locate task file: `--file path` → `.claude/marathon-tasks.md` → error with hint to run `/marathon-tasks`
3. Parse and validate task file
4. Check for `<!-- resume_after: ... -->` marker — if present and time has passed, resume from last incomplete task
5. Create `.claude/marathon.local.md` state file
6. Offer to install statusLine if not configured (strongly recommended for accurate quota monitoring)
7. Activate quota monitor hook
8. If `--orchestrate`: invoke orchestration skill, begin autonomous dispatch
9. If advisory (default): activate monitoring only, user drives the session
10. Notify: `"Marathon started: {n} tasks, mode: {mode}"`

### `/marathon-status`

Display current marathon state:

```
Marathon Active | Orchestrate Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Task:     3/8 — "Add vitest coverage for cache module"
Model:    sonnet (auto: medium complexity)
Zone:     GREEN (42% used)
Resets:   2h13m (off-peak)
Wake:     07:30 (4h22m remaining)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Completed: 2 | Remaining: 6 | Skipped: 0
```

### `/marathon-stop`

Graceful wind-down (same as automatic ORANGE behavior, but user-initiated):

1. Commit current work (WIP prefix if mid-task)
2. Update PROJECT_LOGs for completed tasks
3. Update task file — check off completed, note WIP
4. Push all commits
5. Notify: `"Marathon stopped: {completed}/{total} done"`
6. Remove state file

### `/marathon-tasks [--source path] [--scan]`

Build a task list for marathon execution.

- `--scan`: Scan all projects in working directory:
  - Dirty repos → "Commit/push pending changes in {project}"
  - Unpushed commits → "Push {n} commits in {project}"
  - Stale branches → "Clean up branches in {project}"
  - PROJECT_LOG "Next Steps" → actionable items
  - `TODO`/`FIXME`/`HACK`/`XXX` in code → grouped by project
- `--source path`: Parse a projects file (e.g., `projects.md`) and extract actionable items from status fields, known issues, pending work
- No args: Interactive — ask what to work on, help prioritize, write the file

Output: `.claude/marathon-tasks.md` (or user-specified path). Always presented for user review before execution.

### `/marathon-schedule [--platform auto|macos|linux|cron] [--start HH:MM] [--stop HH:MM] [--days weekdays|daily|custom]`

Generate and optionally install platform-native scheduler configs.

**macOS:** Generates a launchd plist → `~/Library/LaunchAgents/com.marathon-mode.nightly.plist`. Offers to `launchctl load` it.

**Linux:** Generates systemd timer + service units → `~/.config/systemd/user/`. Offers to `systemctl --user enable` them.

**Cron:** Generates crontab entry. Offers to install via `crontab`.

All configs launch Claude Code with: `claude -p "/marathon --orchestrate --wake-time {stop} --file .claude/marathon-tasks.md"`

Supports `--regenerate` (update existing) and `--uninstall` (remove).

Schedule settings persist to `.claude/marathon-config.local.md`.

## Notifications

### Supported Types

| Type | Config | Mechanism |
|------|--------|-----------|
| `ntfy` | `notification_url` | POST to ntfy.sh endpoint. Compatible with Noti, ntfy apps. |
| `webhook` | `notification_url` | POST JSON `{"title": "...", "message": "..."}`. Works with Slack/Discord webhooks, Moshi, custom endpoints. |
| `osascript` | (none needed) | macOS native notification via `display notification`. Local only. |
| `none` | | Silent operation. |

### Notification Events

- Marathon started
- Task completed (concise: `"✅ 3/8: {summary}"`)
- Zone transition (YELLOW, ORANGE, RED, COAST, back to GREEN)
- Wind-down initiated
- Marathon complete (with summary)
- Error/blocker encountered

### Implementation

A `notify.sh` script reads type + URL from config and dispatches. Uses `jq` for safe JSON construction to avoid injection:

```bash
#!/bin/bash
set -euo pipefail

TITLE="$1"
MESSAGE="$2"
CONFIG_FILE=".claude/marathon-config.local.md"

# Parse notification settings from config frontmatter
NOTIFICATION_TYPE=$(sed -n '/^---$/,/^---$/{ /^notification_type:/{ s/notification_type: *//; p; }}' "$CONFIG_FILE")
NOTIFICATION_URL=$(sed -n '/^---$/,/^---$/{ /^notification_url:/{ s/notification_url: *//; s/^"//; s/"$//; p; }}' "$CONFIG_FILE")

case "$NOTIFICATION_TYPE" in
  ntfy)
    curl -s -d "$MESSAGE" -H "Title: $TITLE" "$NOTIFICATION_URL" >/dev/null 2>&1
    ;;
  webhook)
    jq -n --arg title "$TITLE" --arg message "$MESSAGE" \
      '{"title":$title,"message":$message}' | \
      curl -s -X POST -H "Content-Type: application/json" -d @- "$NOTIFICATION_URL" >/dev/null 2>&1
    ;;
  osascript)
    osascript -e "display notification \"$(echo "$MESSAGE" | sed 's/"/\\"/g')\" with title \"$(echo "$TITLE" | sed 's/"/\\"/g')\""
    ;;
  none|"")
    ;;
esac
```

## StatusLine Integration (Optional but Recommended)

Users can add the marathon StatusLine script for a persistent quota display and accurate quota monitoring:

```
5h: 42% | 7d: 18% | resets: 2h13m | ZONE: GREEN | task 3/8
```

The StatusLine script is **display-only in its output** but writes quota data to `/tmp/` as a side effect. This is the primary data source for the PostToolUse hook. Without StatusLine, the hook falls back to JSONL parsing (less precise).

**StatusLine script configuration (settings.json):**

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/marathon-mode/scripts/statusline-quota.sh"
  }
}
```

Note: `${CLAUDE_PLUGIN_ROOT}` is not available in settings.json context. The `/marathon` command outputs the full resolved path when offering to configure StatusLine, and the user (or the command itself) writes the absolute path to settings.json.

## Hooks

### PostToolUse: `quota-monitor.sh`

Fires after every tool call. Target latency: < 200ms (state files in `/tmp/` and `.claude/` avoid iCloud latency).

**Input (JSON on stdin):**
```json
{
  "session_id": "abc-123",
  "transcript_path": "/path/to/session.jsonl",
  "cwd": "/path/to/working/dir",
  "tool_name": "Bash",
  "tool_input": { "command": "..." }
}
```

**Logic:**
1. Check if marathon is active (`.claude/marathon.local.md` exists)
2. Verify session_id matches (skip if different session)
3. Read quota data from `/tmp/marathon-quota-{session_id}.json` (StatusLine path) or fall back to JSONL parsing
4. Calculate current zone
5. Compare to `quota_zone` in state file
6. If zone changed:
   - Update state file with new zone
   - Emit `systemMessage` with zone transition guidance
   - Call `notify.sh` for significant transitions (YELLOW+)
7. If zone unchanged: exit silently (exit code 0, no stdout)

**Output format (on zone change only):**

```json
{
  "systemMessage": "⚠️ YELLOW: 73% used, resets in 1h42m. Finish current task, then sequential only."
}
```

### Stop: `stop-hook.sh`

Handles task cycling in orchestrate mode and clean exit during COAST.

**Input (JSON on stdin):**
```json
{
  "session_id": "abc-123",
  "transcript_path": "/path/to/session.jsonl",
  "cwd": "/path/to/working/dir"
}
```

The hook extracts the last assistant message by parsing the JSONL transcript (same technique as Ralph Loop's stop hook).

**Logic:**
1. Check if marathon is active
2. Verify session_id matches
3. If COAST zone and all state saved → allow exit (exit 0). Scheduler handles restart.
4. If tasks remain and quota zone is GREEN/YELLOW:
   - Block exit: `{"decision": "block", "reason": "{next task prompt}"}`
   - Increment `current_task` in state file
5. If all tasks complete or RED zone with wind-down complete → allow exit, remove state file

## Composability

### With Ralph Loop

Marathon manages the session budget. Ralph handles individual iterative tasks:

```
/marathon --orchestrate --file tasks.md
  ↓
Task 3: "Get all spirittrax tests passing"
  ↓
Orchestrator dispatches with Ralph-compatible prompt:
  "Fix failing scrapers until all tests pass.
   Output <promise>ALL TESTS PASSING</promise> when done."
  ↓
Ralph iterates within the subagent until tests pass
  ↓
Marathon checks off task, moves to task 4
```

### With Superpowers

The orchestrator can invoke superpowers skills within subagent prompts:
- `verification-before-completion` for deployment tasks
- `systematic-debugging` for bug fix tasks
- `test-driven-development` for test writing tasks

### With Any MCP Server

Marathon doesn't depend on specific MCP servers. Whatever the user has configured (Discord, Cloudflare, Chrome DevTools, etc.) is available to subagents during task execution.

## Edge Cases

### Session Dies Unexpectedly

State file and task file persist. Next `/marathon` invocation detects existing state, offers to resume from last completed task. No data is lost because completed tasks are checked off in the task file and committed before each new task starts.

### Task Fails / Subagent Errors

Mark task as `[FAILED]` in task file with error note. Move to next task. Include failure in session summary notification. User can re-attempt failed tasks in a subsequent marathon.

### All Tasks Complete Before Quota Exhausted

Clean finish: update all docs, push, notify with full summary, remove state file. Remaining quota is available for interactive use.

### Wake Time Approaching During COAST

If wake_time is within 30 minutes when COAST triggers, skip the scheduler-restart pattern and do a final wind-down instead. The user is returning soon — leave things clean.

### No StatusLine Configured

PostToolUse hook falls back to JSONL parsing. It reads cumulative token counts from the session transcript and uses conservative thresholds for zone estimation. This is significantly less precise because:
- Server-side percentage accounts for all concurrent sessions
- Token-to-percentage mapping depends on plan tier (unknown to client)
- 429 responses in the JSONL serve as a hard RED signal

The hook logs a one-time suggestion to configure StatusLine for accurate monitoring.

### Multiple Claude Code Sessions

The session_id in the state file ensures only the marathon session responds to hooks. Other sessions are unaffected. However, other sessions consume shared quota — the quota monitor will see this reflected in `used_percentage` automatically since it's server-side. For maximum autonomous productivity, only the marathon session should be running.

### Weekly Quota Exhaustion

If `seven_day.used_percentage` exceeds 90%, the zone triggers YELLOW regardless of five_hour state. This prevents burning through the remaining weekly quota while the 5-hour window looks green.

## Non-Goals

- **Token-level budgeting:** We don't try to predict how many tokens a task will consume. The server-side `used_percentage` is the single source of truth.
- **Cost optimization:** Marathon focuses on quota efficiency, not dollar cost. Model selection is about capability fit, not price.
- **Multi-machine coordination:** Marathon manages one session on one machine. The scheduler can run on multiple machines but each is independent.
- **Plugin marketplace publishing (v1):** First release is a GitHub repo with manual installation. Marketplace listing is a future goal.
