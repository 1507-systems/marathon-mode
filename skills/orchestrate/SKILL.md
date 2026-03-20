---
name: orchestrate
description: "Autonomous task dispatch with model right-sizing, parallel execution, and quota-aware wind-down. Invoked by /marathon --orchestrate."
---

# Orchestration Skill

This skill drives the marathon dispatch loop: parsing tasks, building dependency tiers, selecting models, dispatching subagents, and managing wind-down. It is the core execution engine invoked by `/marathon --orchestrate`.

## 1. Task File Parsing

Read the task file path from `.claude/marathon.local.md` (the `tasks_file` field in the state block).

Parse the markdown checklist using these conventions:

| Marker | Meaning |
|--------|---------|
| `- [ ]` | Pending task |
| `- [x]` | Completed task |
| `- [WIP]` | Work in progress from a previous session |
| `- [FAILED]` | Task that failed in a previous run |

**Inline metadata** appears as HTML comments on the line immediately after a task:

- `<!-- model: opus|sonnet|haiku -->` — Force a specific model for this task.
- `<!-- after: Task description prefix -->` — Hard dependency; wait for the referenced task to complete before starting this one.
- `<!-- independent -->` — Safe to run in parallel with other tasks in the same project/directory.

**File-level metadata** appears at the top of the task file:

- `<!-- resume_after: timestamp -->` — This file was written by a previous marathon session that entered COAST mode. The orchestrator should wait until the given timestamp before resuming (quota reset window).

**Priority sections** use heading levels: `## Priority 1`, `## Priority 2`, `## Priority 3`, `## Priority 4`. Tasks under Priority 1 execute first; within a priority level, dependency tiers determine ordering.

## 2. Dependency Tier Construction

Group tasks within each priority level into execution tiers based on independence:

**Default rules:**
- Tasks targeting DIFFERENT projects or directories are independent by default.
- Tasks targeting the SAME project or directory are sequential by default (one after another).

**Overrides:**
- `<!-- independent -->` on a same-project task marks it safe for parallel execution.
- `<!-- after: X -->` creates an explicit hard dependency — the task cannot start until the task whose description starts with `X` is marked `[x]`.

**Tier assignment:**
- **Tier 1:** Tasks with zero unmet dependencies.
- **Tier 2:** Tasks whose dependencies are all satisfied by Tier 1 completions.
- **Tier N:** Tasks whose dependencies are all satisfied by Tier N-1 completions.

Execute all tasks in a tier (respecting parallelism limits) before advancing to the next tier.

## 3. Model Selection

### 3a. Complexity Assessment

For each task, infer complexity from its description text:

**Simple (Haiku):**
Keywords/signals: "update PROJECT_LOG", "push commits", "clean branches", "update docs", "formatting", "rename", "move file", "delete", "config edit", "find and replace", "bump version", "update changelog"

**Medium (Sonnet):**
Keywords/signals: "add tests", "write tests", "fix bug", "deploy", "update CI", "install dependency", "migration", "straightforward", "simple fix", "add endpoint", "wire up", "connect"

**Complex (Opus):**
Keywords/signals: "refactor", "new feature", "implement", "architecture", "security audit", "debug complex", "multi-file", "design", "API design", "performance", "integrate", "overhaul"

### 3b. Explicit Override

If `<!-- model: X -->` is present on the task, use that model regardless of complexity assessment.

### 3c. Quota Downshift

After determining the base model, apply a downshift based on the current `quota_zone` (read from `.claude/marathon.local.md`):

| Zone | Adjustment |
|------|-----------|
| GREEN | No change |
| YELLOW | opus -> sonnet; sonnet and haiku unchanged |
| ORANGE | opus -> sonnet; sonnet -> haiku; haiku unchanged |
| RED | Everything -> haiku |

The final model after downshift is what gets passed to the subagent.

## 4. Dispatch Loop

```
For each priority level (1, 2, 3, 4):
  Build dependency tiers from pending tasks at this priority
  For each tier:
    1. Read current quota_zone from .claude/marathon.local.md
    2. If quota_zone is RED:
       Execute wind-down sequence (Section 6) -> STOP
    3. If quota_zone is ORANGE:
       Execute wind-down sequence (Section 6) -> STOP
    4. Determine max parallelism from quota_zone:
       - GREEN: dispatch all independent tasks in the tier simultaneously
       - YELLOW: dispatch at most 2 tasks simultaneously
       - ORANGE: 1 (but wind-down is already triggered above)
       - RED: 0 (already stopped above)
    5. For each task (or parallel batch of tasks):
       a. Assess model via complexity detection + quota downshift (Section 3)
       b. Dispatch via the Agent tool:

          Agent(
            description: "Marathon task {n}/{total}: {brief summary}",
            prompt: "{full task description}\n\n{discipline rules from Section 5}\n\n{relevant context: project path, current branch, etc.}",
            model: "{final_model_after_downshift}"
          )

       c. When the subagent returns:
          - Verify it committed its changes (check git log for new commits)
          - Mark the task as complete: change `- [ ]` to `- [x]` in the task file
          - Run: git add {tasks_file} && git commit -m "marathon: complete task {n}/{total}" && git push
          - Update current_task in .claude/marathon.local.md
          - Send notification: "Task {n}/{total}: {summary}"
       d. Re-read quota_zone from .claude/marathon.local.md (the quota hook may have updated it)
    6. All tasks in this tier complete -> advance to the next tier
  All tiers at this priority complete -> advance to the next priority level
```

## 5. Discipline Rules

Every subagent prompt MUST have these rules appended, verbatim:

```
MARATHON DISCIPLINE RULES:
1. Commit your changes before finishing — do not leave uncommitted work.
2. Update PROJECT_LOG.md with what you did — include what changed and why.
3. Only work on this specific task — do not start other tasks or "while I'm here" fixes.
4. If blocked, document the blocker in the task file and complete without resolving it.
```

These rules prevent scope creep, ensure traceability, and keep the task file accurate.

## 6. Wind-Down Sequence

### Triggers

Wind-down is triggered when any of these conditions are met:
- `quota_zone` reaches ORANGE or RED
- `wake_time` is within 30 minutes of the current time
- All tasks in the task file are complete
- The user runs `/marathon-stop`

### Steps

1. **Wait for active work.** If a subagent is currently running, let it finish. Never interrupt a task mid-execution.

2. **Verify commits.** Confirm all completed tasks have their changes committed and pushed. If any are uncommitted, commit and push them now.

3. **Update the task file** with accurate markers:
   - Completed tasks: `- [x]`
   - Task that was in progress when wind-down triggered: `- [WIP] {description}`
   - Remaining tasks: `- [ ]`

4. **Branch by reason:**

   **COAST zone (>95% quota used but reset is imminent):**
   - Write `<!-- resume_after: {reset_timestamp + 60s} -->` to the top of the task file.
   - Notify: "COAST: Pausing for quota reset. {n} tasks remaining."
   - Leave `.claude/marathon.local.md` in place (the scheduler will restart the marathon after reset).

   **All tasks complete:**
   - Notify: "Marathon Complete: {completed}/{total} tasks done in {duration}"
   - Remove `.claude/marathon.local.md`.

   **Wind-down (ORANGE/RED/wake approaching):**
   - Notify: "Marathon winding down: {completed}/{total} done, {remaining} remaining"
   - Remove `.claude/marathon.local.md`.

5. **Show final summary** with completed count, failed count, remaining count, and total elapsed time.

## 7. Error Handling

**Subagent failure:**
- Mark the task as `- [FAILED] {description}` in the task file.
- Append a note: `<!-- error: {brief error description} -->`
- Notify: "Task {n} failed: {brief description}"
- Continue to the next task. Do not stop the marathon for a single failure.

**Git push failure:**
- Log the error in the task file as a comment.
- Continue execution. Pushes can be retried later.

**Notification failure:**
- Ignore silently. The notify script already handles its own error cases.

**Task file parse error:**
- If the task file is malformed or missing, notify the user and stop the marathon gracefully.

## 8. Resuming a Previous Session

When the orchestrator starts, check for signs of a previous session:

1. **Completed tasks** — Any `- [x]` entries in the task file indicate prior progress.
2. **Resume marker** — A `<!-- resume_after: {timestamp} -->` at the top means a COAST pause. If the current time is past the timestamp, proceed. If not, wait.
3. **WIP tasks** — A `- [WIP]` entry means a task was interrupted. Treat it as the next task to execute (restart it from scratch; partial work should already be committed).

When resuming:
- Skip all `- [x]` tasks.
- Restart any `- [WIP]` task (change it back to `- [ ]` before dispatching).
- Announce: "Resuming marathon from task {n}/{total}"
- Continue the normal dispatch loop from there.
