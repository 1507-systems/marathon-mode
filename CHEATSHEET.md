# Marathon Mode — Cheat Sheet

## Commands

Everything is a single `/marathon` command with subcommands:

```
/marathon                           # Start advisory session
/marathon --orchestrate             # Start orchestrate (autonomous) session
/marathon --orchestrate --wake-time 07:30   # Overnight autonomous run
/marathon --file ./my-tasks.md      # Use a specific task file

/marathon tasks                     # Build task list interactively
/marathon tasks --scan              # Scan repos for TODOs/dirty state
/marathon tasks --source projects.md  # Extract from a projects file

/marathon status                    # Check session state + quota
/marathon stop                      # Graceful wind-down
/marathon schedule                  # Set up nightly launchd automation
/marathon schedule --uninstall      # Remove scheduler config
```

## Modes

- **Advisory** (default) — quota monitor runs in background, you work normally, warns on zone transitions
- **Orchestrate** — Claude reads tasks, picks models, dispatches subagents, manages wind-down autonomously

## Task Format

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

## Status Display

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
/marathon tasks --scan
# review task list
/marathon --orchestrate --wake-time 07:30
```

**Manual session with quota monitoring:**
```
/marathon tasks
# edit .claude/marathon-tasks.md to taste
/marathon
# work normally, quota monitor warns you
/marathon stop
```

**Recurring nightly automation:**
```
/marathon tasks --scan
/marathon schedule --start 22:00 --stop 07:30
```

## Files

| File | Purpose |
|------|---------|
| `.claude/marathon-tasks.md` | Task list (checklist format) |
| `.claude/marathon.local.md` | Active session state (auto-managed) |
| `.claude/marathon-config.local.md` | Saved schedule/notification settings |
