# Marathon Mode — Cheat Sheet

## Commands

| Command | What it does |
|---------|-------------|
| `/marathon` | Start a marathon session |
| `/marathon-tasks` | Build/scan a task list |
| `/marathon-status` | Check session state + quota |
| `/marathon-stop` | Graceful wind-down |
| `/marathon-schedule` | Set up automated nightly runs |

## /marathon

Start a quota-aware work session.

```
/marathon                           # Advisory mode (you drive, quota monitored)
/marathon --orchestrate             # Autonomous mode (Claude dispatches tasks)
/marathon --file ./my-tasks.md      # Use a specific task file
/marathon --wake-time 07:30         # Wind down at 7:30 AM
/marathon --orchestrate --wake-time 07:30   # Overnight autonomous run
```

**Modes:**
- **Advisory** (default) — quota monitor runs in background, you work normally, warns on zone transitions
- **Orchestrate** — Claude reads tasks, picks models, dispatches subagents, manages wind-down autonomously

## /marathon-tasks

Build a prioritized task list at `.claude/marathon-tasks.md`.

```
/marathon-tasks --scan              # Scan working directory for TODOs, dirty repos, etc.
/marathon-tasks --source projects.md  # Extract tasks from a projects file
/marathon-tasks                     # Interactive — build list through conversation
```

**Task format:**
```markdown
## Priority 1 (Critical)
- [ ] Fix broken auth endpoint
  <!-- model: opus -->

## Priority 2 (High)
- [ ] Deploy staging build
  <!-- model: sonnet -->
  <!-- after: Fix broken auth endpoint -->

## Priority 3 (Normal)
- [ ] Update README
  <!-- model: haiku -->
```

**Model hints:** `<!-- model: haiku|sonnet|opus -->` — right-sizes per task
**Dependencies:** `<!-- after: task description -->` — sequential ordering

## /marathon-status

```
Marathon Active | Orchestrate Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Task:     3/12 — "Deploy staging build"
Model:    sonnet
Zone:     GREEN (23% used)
Resets:   4h 12m (5-hour window)
Wake:     07:30 (5h 45m remaining)
Duration: 2h 18m
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Completed: 2 | Remaining: 10 | Failed: 0 | WIP: 0
```

## /marathon-stop

Graceful shutdown: commits WIP, updates task file, pushes repos, sends notification.

```
/marathon-stop
```

## /marathon-schedule

Set up automated nightly marathon runs via launchd (macOS) or systemd/cron (Linux).

```
/marathon-schedule                                    # Defaults: 10 PM–7:30 AM daily
/marathon-schedule --start 23:00 --stop 06:00         # Custom hours
/marathon-schedule --days weekdays                    # Weekdays only
/marathon-schedule --uninstall                        # Remove scheduler
```

## Quota Zones

| Zone | Usage | Behavior |
|------|-------|----------|
| GREEN | 0–60% | Full speed, all models available |
| YELLOW | 60–80% | Downshift models (opus→sonnet, sonnet→haiku) |
| ORANGE | 80–95% | Wind-down: finish current task, commit, stop |
| RED | 95%+ | Emergency stop, commit WIP immediately |

## Typical Workflows

**Quick overnight run:**
```
/marathon-tasks --scan
# review task list
/marathon --orchestrate --wake-time 07:30
```

**Manual session with quota monitoring:**
```
/marathon-tasks
# edit .claude/marathon-tasks.md to taste
/marathon
# work normally, quota monitor warns you
/marathon-stop
```

**Recurring nightly automation:**
```
/marathon-tasks --scan
/marathon-schedule --start 22:00 --stop 07:30
```

## Files

| File | Purpose |
|------|---------|
| `.claude/marathon-tasks.md` | Task list (checklist format) |
| `.claude/marathon.local.md` | Active session state (auto-managed) |
| `.claude/marathon-config.local.md` | Saved schedule/notification settings |
