---
name: orchestrate
description: "Autonomous task dispatch with model right-sizing, parallel execution, and quota-aware wind-down. Invoked by /marathon --orchestrate."
---

# Orchestration Skill

This skill drives the marathon dispatch loop: parsing tasks, building a global dependency graph, selecting models, dispatching subagents, monitoring via watchdog, and managing wind-down. It is the core execution engine invoked by `/marathon --orchestrate` (or `/marathon` with the `--orchestrate` flag).

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
- `<!-- project: project-name -->` — Identifies which project this task belongs to (used for same-project sequential default).
- `<!-- requires: hardware|gui|verve -->` — Task requires manual/physical interaction. **Never dispatched** by the orchestrator. Reported as "Skipped (manual)" in the wind-down summary.
- `<!-- blocked: keychain -->` — Task requires macOS keychain access but the keychain is locked (headless session). **Never dispatched.** Reported as "Skipped (keychain locked)" in the wind-down summary.
- `<!-- error: description -->` — Error note from a previous failure.
- `<!-- note: description -->` — Informational note (no behavioral effect).

**File-level metadata** appears at the top of the task file:

- `<!-- resume_after: timestamp -->` — This file was written by a previous marathon session that entered COAST mode. The orchestrator should wait until the given timestamp before resuming (quota reset window).

**Priority sections** use heading levels: `## Priority 1`, `## Priority 2`, `## Priority 3`, `## Priority 4`. Priority is used as a **tie-breaker** for dispatch ordering, not as a sequential gate. A P4 task with no dependencies can run alongside a P1 task.

## 2. Global Dependency Graph

Build a **single global dependency graph** across ALL priority levels. Do NOT process priorities sequentially — all tasks from all priorities are in one graph.

**Default rules:**
- Tasks targeting DIFFERENT projects or directories are **independent** by default.
- Tasks targeting the SAME project or directory are **sequential** by default (one after another, in file order).

**Overrides:**
- `<!-- independent -->` on a same-project task marks it safe for parallel execution within that project.
- `<!-- after: X -->` creates an explicit hard dependency — the task cannot start until the task whose description starts with `X` is marked `[x]` or `[FAILED]`.

**Eligibility rules — a task is ELIGIBLE for dispatch when ALL of these are true:**
1. The task is pending (`- [ ]`) — not `[x]`, `[FAILED]`, `[WIP]`, or currently running.
2. All explicit dependencies (`<!-- after: X -->`) are satisfied (predecessor is `[x]` or `[FAILED]`).
3. No same-project task is currently running (unless this task has `<!-- independent -->`).
4. The task does NOT have a `<!-- requires: ... -->` annotation (manual/hardware tasks are never dispatched).
5. The task does NOT have a `<!-- blocked: keychain -->` annotation.

**Sorting eligible tasks for dispatch order:**
1. Priority ASC (P1 tasks dispatch before P4 tasks when competing for slots).
2. File order within the same priority (tasks listed first dispatch first).

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

## 4. Agent Registry

The agent registry tracks all active subagents for watchdog monitoring and quota aggregation. It lives at `/tmp/marathon-agents-{session_id}.json`.

### 4a. Registry Format

```json
{
  "agents": [
    {
      "task_id": 5,
      "pid": 0,
      "jsonl_path": "",
      "model": "haiku",
      "started_at": "2026-03-22T01:30:00Z",
      "description": "Update CRM worker docs",
      "retry_count": 0,
      "working_dir": "/path/to/project"
    }
  ],
  "retries": [
    {
      "task_id": 5,
      "model": "sonnet",
      "reason": "stall_escalation",
      "queued_at": "2026-03-22T02:00:00Z"
    }
  ]
}
```

### 4b. Registry Operations

**Before dispatching a subagent:**
1. Add an entry to `agents[]` with the task_id, model, started_at (current UTC ISO), description, retry_count, and working_dir.
2. Set `pid` to 0 and `jsonl_path` to "" (placeholders — the watchdog discovers the actual JSONL by scanning `~/.claude/projects/*/sessions/*.jsonl` for recently-created files).

**When a subagent completes (success or failure):**
1. Remove the agent's entry from `agents[]`.

**On each dispatch loop iteration:**
1. Check `retries[]` for pending retry tasks. For each retry entry:
   - Remove it from `retries[]`.
   - Change the task marker back to `- [ ]` in the task file (if it was marked `[FAILED]`).
   - Dispatch the task with the escalated model specified in the retry entry.
   - Add a new `agents[]` entry with `retry_count` incremented.

### 4c. Watchdog Launch

After creating the registry file, launch the watchdog as a background process:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" "{session_id}" &
```

Record the watchdog PID in `.claude/marathon.local.md` (the `watchdog_pid` field).

## 5. Dispatch Loop

```
1. Initialize the agent registry file (empty agents[], empty retries[])
2. Launch watchdog (Section 4c)
3. While pending or running tasks exist:
   a. Read current quota_zone from .claude/marathon.local.md
   b. If quota_zone is RED or ORANGE:
      Execute wind-down sequence (Section 8) -> STOP
   c. Check watchdog retry queue:
      - Read retries[] from registry
      - For each retry: reset task to [ ], remove from retries[], add to dispatch pool
   d. Determine max parallelism from quota_zone:
      - GREEN: unlimited (dispatch all eligible tasks)
      - YELLOW: 2 concurrent tasks max
   e. Find all ELIGIBLE tasks (Section 2 eligibility rules)
   f. Sort eligible tasks by: priority ASC, then file order
   g. Dispatch up to (max_parallel - currently_running) tasks from the sorted list:
      For each task to dispatch:
        i.   Assess model via complexity detection + quota downshift (Section 3)
        ii.  Register in agent registry (Section 4b)
        iii. Dispatch via the Agent tool:

             Agent(
               description: "Marathon task {n}/{total}: {brief summary}",
               prompt: "{full task description}\n\n{discipline rules from Section 6}\n\n{relevant context: project path, current branch, etc.}",
               model: "{final_model_after_downshift}",
               run_in_background: true
             )

   h. When any background agent completes:
      - Remove from agent registry
      - Verify it committed its changes (check git log for new commits)
      - Mark the task as complete: change `- [ ]` to `- [x]` in the task file
      - Update current_task in .claude/marathon.local.md
      - Send notification: "Task {n}/{total}: {summary}"
      - Re-read quota_zone (the quota hook may have updated it)
      - Re-evaluate eligibility (new tasks may become unblocked)
      - Dispatch newly eligible tasks (loop back to step e)
   i. If no eligible tasks AND no running tasks:
      - All remaining tasks are blocked (manual/keychain/dependency cycles)
      - Report blocked tasks and proceed to wind-down
```

**Key behavioral changes from v1:**
- Priority is a tie-breaker, NOT a gate. P4 tasks with no dependencies run alongside P1 tasks.
- A stalled/failed task only blocks tasks that explicitly depend on it (or are in the same project), not all lower-priority work.
- All background agents dispatch with `run_in_background: true` for maximum parallelism.

## 6. Discipline Rules

Every subagent prompt MUST have these rules appended, verbatim:

```
MARATHON DISCIPLINE RULES:
1. Read before you write — ALWAYS read every file you plan to modify before making changes. Never generate fixes from task descriptions alone. Verify the current state of the code first.
2. Commit your changes before finishing — do not leave uncommitted work.
3. Update PROJECT_LOG.md with what you did — include what changed and why.
4. Only work on this specific task — do not start other tasks or "while I'm here" fixes.
5. If blocked, document the blocker in the task file and complete without resolving it.
```

These rules prevent scope creep, ensure traceability, and keep the task file accurate.

## 7. Error Handling

**Subagent failure:**
- Mark the task as `- [FAILED] {description}` in the task file.
- Append a note: `<!-- error: {brief error description} -->`
- Remove from agent registry.
- Notify: "Task {n} failed: {brief description}"
- Continue to the next task. Do not stop the marathon for a single failure.

**Stalled agent (detected by watchdog):**
- The watchdog handles SIGTERM/SIGKILL and marks the task as FAILED.
- The watchdog adds a retry entry to the registry if retry_count < MAX_RETRIES.
- The orchestrator picks up retries on the next loop iteration (Section 5, step c).
- Model escalation on retry: haiku -> sonnet, sonnet -> opus, opus -> opus (then permanent FAILED).

**Git push failure:**
- Log the error in the task file as a comment.
- Continue execution. Pushes can be retried later.

**Notification failure:**
- Ignore silently. The notify script already handles its own error cases.

**Task file parse error:**
- If the task file is malformed or missing, notify the user and stop the marathon gracefully.

## 8. Wind-Down Sequence

### Triggers

Wind-down is triggered when any of these conditions are met:
- `quota_zone` reaches ORANGE or RED
- `wake_time` is within 30 minutes of the current time
- All dispatchable tasks are complete (remaining tasks are manual/keychain/blocked)
- The user runs `/marathon stop`

### Steps

1. **Wait for active work.** If subagents are currently running, let them finish. Never interrupt a task mid-execution.

2. **Kill the watchdog.** Send SIGTERM to the watchdog PID (from `.claude/marathon.local.md`). The watchdog handles SIGTERM gracefully.

3. **Verify commits.** Confirm all completed tasks have their changes committed and pushed. If any are uncommitted, commit and push them now.

4. **Update the task file** with accurate markers:
   - Completed tasks: `- [x]`
   - Task that was in progress when wind-down triggered: `- [WIP] {description}`
   - Remaining tasks: `- [ ]`

5. **Branch by reason:**

   **COAST zone (>95% quota used but reset is imminent):**
   - Write `<!-- resume_after: {reset_timestamp + 60s} -->` to the top of the task file.
   - Notify: "COAST: Pausing for quota reset. {n} tasks remaining."
   - Leave `.claude/marathon.local.md` in place (the scheduler will restart the marathon after reset).

   **All dispatchable tasks complete:**
   - Notify: "Marathon Complete: {completed}/{total} tasks done in {duration}"
   - Remove `.claude/marathon.local.md`.

   **Wind-down (ORANGE/RED/wake approaching):**
   - Notify: "Marathon winding down: {completed}/{total} done, {remaining} remaining"
   - Remove `.claude/marathon.local.md`.

6. **Clean up temp files:**
   - Remove `/tmp/marathon-agents-{session_id}.json`
   - Remove `/tmp/marathon-stall-log-{session_id}.jsonl`
   - Remove `/tmp/marathon-quota-{session_id}.json`

7. **Show final summary** with completed count, failed count, skipped (manual) count, skipped (keychain) count, remaining count, stall count (from stall log), and total elapsed time.

   Include the stall log contents if any stalls were detected during the run.

8. **Write post-run summary report** to `.claude/marathon-report-{session_id}.md`:

   Read the following data before writing:
   - State file fields captured before cleanup: `started_at`, `mode`, `wake_time`, `session_id`
   - Current UTC time for `ended_at` and duration calculation
   - Task file: re-parse completed (`- [x]`), failed (`- [FAILED]`), WIP (`- [WIP]`), manual (`<!-- requires: -->`), keychain-blocked (`<!-- blocked: keychain -->`) tasks and their model hints
   - Stall log at `/tmp/marathon-stall-log-{session_id}.jsonl` (if it exists, read before cleanup)
   - Last quota snapshot at `/tmp/marathon-quota-{session_id}.json` (if it exists, read before cleanup)

   Report format:

   ```markdown
   # Marathon Session Report

   **Session ID:** {session_id}
   **Mode:** {advisory|orchestrate}
   **Started:** {started_at UTC}
   **Ended:** {ended_at UTC}
   **Duration:** {Xh Ym}
   **Wake time:** {wake_time or "not set"}

   ## Task Results

   | # | Description | Status | Model | Project |
   |---|-------------|--------|-------|---------|
   | 1 | {description} | ✅ Completed | haiku | {project} |
   | 2 | {description} | ❌ Failed | sonnet | {project} |
   | 3 | {description} | ⏭ Skipped (manual) | — | {project} |
   | 4 | {description} | 🔑 Skipped (keychain) | — | {project} |
   | 5 | {description} | ⏳ Remaining | — | {project} |

   **Summary:** {completed} completed, {failed} failed, {skipped_manual} skipped (manual), {skipped_keychain} skipped (keychain), {remaining} remaining

   ## Quota Usage

   **5-hour usage:** {five_hour_pct}%
   **7-day usage:** {seven_day_pct}%
   **Zone at wind-down:** {zone}
   **Resets at:** {resets_at or "unknown"}

   *(Source: {statusline|jsonl|none})*

   ## Stall Log

   {If no stalls: "No stalls detected during this session."}

   {If stalls detected: table with columns: Task ID | Description | Stall detected at | Action taken | Retry model}

   ## Skipped Tasks

   {If none: "No tasks were skipped."}

   {If any manual/keychain tasks: list each with reason}
   - **{description}** — Skipped: {manual (requires: gui/verve/hardware) | keychain locked}
   ```

   After writing the report, output: `Report written to .claude/marathon-report-{session_id}.md`

## 9. Resuming a Previous Session

When the orchestrator starts, check for signs of a previous session:

1. **Completed tasks** — Any `- [x]` entries in the task file indicate prior progress.
2. **Resume marker** — A `<!-- resume_after: {timestamp} -->` at the top means a COAST pause. If the current time is past the timestamp, proceed. If not, wait.
3. **WIP tasks** — A `- [WIP]` entry means a task was interrupted. Treat it as the next task to execute (restart it from scratch; partial work should already be committed).

When resuming:
- Skip all `- [x]` tasks.
- Restart any `- [WIP]` task (change it back to `- [ ]` before dispatching).
- Announce: "Resuming marathon from task {n}/{total}"
- Continue the normal dispatch loop from there.
