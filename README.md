# Marathon Mode

Quota-aware autonomous work sessions for Claude Code.

---

## What it does

- **Real-time quota monitoring** — tracks both 5-hour and 7-day rate limits via StatusLine integration or JSONL transcript fallback; emits zone-change system messages as you approach limits
- **Per-task model right-sizing** — auto-detects task complexity (Haiku / Sonnet / Opus) from description keywords, with explicit `<!-- model: -->` overrides and automatic quota-based downshift
- **Parallel dispatch with quota-throttled concurrency** — GREEN runs all independent tasks simultaneously; YELLOW caps at 2; ORANGE/RED triggers wind-down
- **Graceful wind-down with clean breakpoints** — waits for in-flight tasks to finish, commits WIP, updates PROJECT_LOGs, pushes, and writes a `<!-- resume_after: -->` marker for automatic resume after quota reset
- **Two modes** — Advisory (monitoring only, you drive) or Orchestrate (full autonomous dispatch via the Stop hook task-cycling loop)

---

## Requirements

| Dependency | Version | Notes |
|---|---|---|
| [jq](https://jqlang.github.io/jq/) | any | Required for quota parsing. `brew install jq` / `apt install jq` |
| Claude Code | 2.1+ | Plugin system required |

---

## Installation

```bash
git clone https://github.com/1507-systems/marathon-mode.git
claude plugin add /path/to/marathon-mode
```

The plugin registers two hooks automatically: a `PostToolUse` quota monitor and a `Stop` hook for task cycling in orchestrate mode.

---

## Quick Start

```bash
# Build a task list by scanning all git repos in the current directory
/marathon tasks --scan

# Review and edit the generated list
# Edit: .claude/marathon-tasks.md

# Start in advisory mode (you drive, quota monitoring active)
/marathon

# Or start in orchestrate mode (fully autonomous)
/marathon --orchestrate

# Schedule an overnight run (stops at 07:30, picks up after quota reset)
/marathon --orchestrate --wake-time 07:30

# Check live session status
/marathon status

# Graceful stop (commits WIP, pushes, cleans up)
/marathon stop
```

---

## Commands

Everything is a single `/marathon` command with subcommands and flags:

| Usage | Description |
|---|---|
| `/marathon` | Start advisory session (quota monitoring, you drive) |
| `/marathon --orchestrate` | Start orchestrate session (autonomous dispatch) |
| `/marathon --orchestrate --wake-time HH:MM` | Overnight autonomous run with wind-down time |
| `/marathon --file path` | Start with a specific task file |
| `/marathon tasks` | Build task list interactively |
| `/marathon tasks --scan` | Scan repos for TODOs, dirty state, unpushed commits |
| `/marathon tasks --source path` | Extract tasks from a projects file |
| `/marathon status` | Show live session state, quota zone, progress |
| `/marathon stop` | Graceful wind-down: commit WIP, push, notify, clean up |
| `/marathon schedule` | Generate and install nightly scheduler configs |
| `/marathon schedule --uninstall` | Remove scheduler config |

---

## Quota Zones

Zones are computed from the 5-hour usage percentage. The quota monitor fires after every tool call and emits a system message on zone transitions.

| Zone | 5-Hour Usage | Behavior |
|---|---|---|
| GREEN | < 70% | Full speed. Unlimited parallel dispatch in orchestrate mode. |
| YELLOW | 70–84% | Sequential only (max 2 parallel). Opus tasks downshift to Sonnet. |
| ORANGE | 85–94% | Wind-down triggered. Finish current task, commit, push, stop. All models downshift one tier. |
| RED | > 95% | Emergency save. Commit WIP immediately, push, notify, halt. Everything runs on Haiku. |
| COAST | > 95% + reset <= 45 min away (or 429 rate-limited + reset imminent) | Save state with `<!-- resume_after: -->` marker and exit. Scheduler restarts after reset. |

---

## Model Selection

In orchestrate mode, each task gets a model assigned in three steps:

1. **Complexity assessment** — keywords in the task description determine the base model:
   - Haiku: `update docs`, `push commits`, `clean branches`, `bump version`, `rename`, `move file`
   - Sonnet: `add tests`, `fix bug`, `deploy`, `migration`, `add endpoint`, `wire up`
   - Opus: `refactor`, `new feature`, `implement`, `architecture`, `security audit`, `performance`

2. **Explicit override** — `<!-- model: opus -->` (or `sonnet` / `haiku`) on the line after a task forces that model regardless of assessment.

3. **Quota downshift** — the final model is capped based on current zone (see table above). A task assessed as Opus in YELLOW runs on Sonnet; in RED everything runs on Haiku.

---

## Task File Format

Tasks live in `.claude/marathon-tasks.md` (or a custom path via `--file`). The format is a standard markdown checklist with optional inline metadata as HTML comments.

```markdown
# Marathon Tasks

Generated: 2026-03-20T02:00:00Z
Source: scan

## Priority 1 (Critical)

- [ ] Fix broken auth middleware in crm-worker
  <!-- model: opus -->

## Priority 2 (High)

- [ ] Add integration tests for the /submit endpoint
  <!-- model: sonnet -->
- [ ] Deploy updated worker to production
  <!-- after: Add integration tests for the /submit endpoint -->

## Priority 3 (Normal)

- [ ] Update PROJECT_LOG.md in home-inventory
  <!-- model: haiku -->
- [ ] Push unpushed commits in lighting-controller
  <!-- model: haiku -->
  <!-- independent -->

## Priority 4 (If Time Permits)

- [ ] Clean up merged branches across all repos
  <!-- model: haiku -->
```

**Markers written during a run:**

| Marker | Meaning |
|---|---|
| `- [x]` | Completed |
| `- [WIP]` | Was in progress when session ended; will restart next run |
| `- [FAILED]` | Failed; run continues with next task |
| `<!-- resume_after: timestamp -->` | Written at top of file by COAST wind-down; scheduler respects it |

**Dependency hint:** `<!-- after: Task description prefix -->` blocks a task until the referenced task is marked `[x]`.

**Parallelism hint:** `<!-- independent -->` marks a same-project task safe to run in parallel with others.

---

## Configuration

Create `.claude/marathon-config.local.md` in your project to enable notifications and set defaults. This file is read by `notify.sh` and `marathon schedule`.

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

**Supported `notification_type` values:**

| Type | Behavior |
|---|---|
| `ntfy` | HTTP POST to `notification_url` with a `Title` header |
| `webhook` | JSON `{"title": "...", "message": "..."}` POST to `notification_url` |
| `osascript` | macOS native notification (no URL needed) |
| `none` | Silence all notifications |

Notifications fire on: session start/stop, zone transitions (YELLOW and above), task completion, and errors.

---

## StatusLine Setup

For accurate quota monitoring, wire the included StatusLine script into Claude Code. This writes a live quota snapshot to `/tmp/marathon-quota-<SESSION_ID>.json` on every tick, which the quota monitor hook reads without touching the API.

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/marathon-mode/scripts/statusline-quota.sh"
  }
}
```

When configured, the status bar displays:

```
5h: 42% | 7d: 18% | resets: 2h13m | ZONE: GREEN | task 3/8
```

Without StatusLine, quota is estimated from the JSONL transcript (less precise; 7-day data unavailable). `/marathon` will offer to add the config automatically on first run.

---

## Scheduling

`/marathon schedule` generates platform-native configs for automated overnight runs. It auto-detects the platform (macOS launchd, Linux systemd, or cron fallback).

```bash
# Generate and install a schedule: start at 22:00, stop at 07:30, every day
/marathon schedule --start 22:00 --stop 07:30 --days daily

# Uninstall
/marathon schedule --uninstall
```

Settings are persisted to `.claude/marathon-config.local.md` so subsequent calls use saved defaults. Verify installation on macOS with `launchctl list | grep marathon`.

---

## Composability

**Ralph Loop:** Marathon Mode works alongside Ralph Loop. Run `/marathon --orchestrate` inside a Ralph session to get quota-aware task cycling on top of Ralph's retry/escalation loop.

**Superpowers / skills:** The orchestration logic lives in `skills/orchestrate/SKILL.md` — a plain-text skill file that `/marathon --orchestrate` reads at runtime. You can fork and modify dispatch behavior (parallelism limits, discipline rules, wind-down triggers) without touching any shell scripts.

**Hooks are additive:** The `PostToolUse` and `Stop` hooks only activate when `.claude/marathon.local.md` is present in the project directory and the session ID matches. Non-marathon sessions are unaffected.

---

## License

MIT — see [LICENSE](LICENSE).
