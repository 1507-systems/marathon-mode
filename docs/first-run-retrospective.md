# Marathon Mode -- First Run Retrospective

**Date:** 2026-03-22
**Run window:** ~01:16 UTC to ~11:20 UTC (~10 hours)
**Operator:** Bryce (remote monitoring via phone notifications)

## Session Statistics

| Metric | Value |
|--------|-------|
| Total tasks dispatched | 48 |
| Projects touched | ~35 |
| Peak parallel agents | 14+ |
| Duration | ~10 hours |
| Models used | Opus (orchestrator), Haiku (simple tasks), Sonnet (medium tasks) |
| Git conflicts | 0 |
| Notification failures | 0 |
| Stalled agents | 3 (Haiku) |
| Manual/hardware-blocked tasks | ~12 (estimated) |
| Estimated success rate | ~70% (tasks that made meaningful progress or completed) |

### Model Distribution (Approximate)

- **Haiku:** ~30 tasks (doc updates, archiving, git housekeeping, pushing commits)
- **Sonnet:** ~12 tasks (bug fixes, deployments, test writing)
- **Opus:** ~6 tasks (refactors, new features, complex debugging)

The model right-sizing worked as designed -- the majority of tasks were simple and correctly assigned to Haiku, conserving quota for complex work.

---

## What Worked Well

### 1. Massive Parallelism Without Conflicts

14+ subagents ran simultaneously with zero git conflicts. The default independence heuristic (different projects = independent) proved correct for this workload. Every agent operated in its own project directory, so there was no contention on shared files.

### 2. Discipline Rules Held

Every subagent followed the four discipline rules:
- Committed before finishing
- Updated PROJECT_LOG.md
- Stayed within task scope (no "while I'm here" drift)
- Documented blockers rather than attempting workarounds

This is the single most important design decision in the orchestrator. Without discipline enforcement, 48 tasks across 35 projects would have produced chaos.

### 3. Notification Pipeline

Push notifications (via the Moshi webhook) worked throughout the entire 10-hour run. The operator received real-time updates on task completions and could monitor progress from a phone. The `notify.sh` script's fire-and-forget pattern (background `curl`, `|| true`) meant notification failures never blocked task execution.

### 4. Task File as Shared State

The markdown checklist (`.claude/marathon-tasks.md`) proved to be an effective shared-state mechanism. The orchestrator updated it after each task completion, providing a persistent record of progress. On inspection after the run, the file accurately reflected which tasks completed, which were blocked, and which remained.

---

## Issues: Root Cause Analysis and Proposed Fixes

### Issue 1: Stalled Haiku Agents (Critical)

**Observed behavior:** Three Haiku agents (CRM docs update, archive socialsiphon repo, archive imapfilter-email-relay repo) stopped producing output. Their JSONL transcript files stopped growing. No completion notification was sent. The agents sat idle for 5+ hours, consuming a process slot but doing no work.

**Root cause:** The Agent tool dispatches a subagent as a subprocess. When that subprocess hangs (network timeout, model API error with no retry, or internal deadlock), the orchestrator has no visibility -- it is blocked on the `Agent()` call, waiting for a return that never comes. There is no timeout on Agent tool invocations, and no external watchdog monitors the JSONL files for activity.

**Impact:** 3 of 48 tasks (~6%) produced no result. More importantly, those 3 process slots were occupied for 5+ hours, reducing effective parallelism during that window.

**Proposed fix:** Implement a WATCHDOG mechanism (detailed in its own section below).

---

### Issue 2: Slow Dispatch / Overly Conservative Parallelism (High)

**Observed behavior:** The orchestrator gated Priority 3 and Priority 4 tasks behind Priority 2 completion, even though the system was in GREEN zone with 20% CPU and 38% memory utilization. The operator had to poke twice to get full parallelism going.

**Root cause:** The orchestrate skill (Section 4, Dispatch Loop) is strictly sequential across priority levels:

```
For each priority level (1, 2, 3, 4):
  Build dependency tiers from pending tasks at this priority
  For each tier:
    ...
```

This means P3 tasks cannot start until ALL P2 tasks (including stalled ones) have resolved. In a 48-task run with 3 stalled agents blocking P2, this creates a cascading delay.

**Proposed fix: Cross-priority dispatch with resource awareness.**

Modify the dispatch loop to allow lower-priority tasks to start when:
1. All remaining higher-priority tasks are either running or blocked (waiting on dependencies).
2. The system has available parallelism slots (CPU/memory headroom).
3. No dependency conflicts exist between the cross-priority tasks.

The key insight is that priority levels express *preference*, not hard sequencing. A P4 doc update with zero dependencies should not wait for a P2 task that is stalled or blocked on external resources.

Proposed pseudocode:

```
Build global dependency graph across all priority levels
While pending tasks exist:
  1. Read quota_zone
  2. Determine max_parallel from zone
  3. Find all ELIGIBLE tasks:
     - All dependencies satisfied
     - No same-project task currently running (unless <!-- independent -->)
     - Sorted by priority (P1 first), then tier
  4. Dispatch up to max_parallel eligible tasks
  5. When any task completes, re-evaluate eligibility
```

---

### Issue 3: Keychain Access Failures (Medium)

**Observed behavior:** Many subagents hit macOS exit code 36 when attempting `security find-generic-password` in a headless (non-GUI) session. Some agents wasted time attempting AppleScript workarounds (`osascript -e 'tell application "System Events"'`) which also failed in headless mode.

**Root cause:** macOS Keychain requires a GUI session (or an unlocked login keychain in a console session) to access secrets interactively. When Claude Code runs as a background process (e.g., via launchd), the keychain is locked and inaccessible. This is a known RogueNode limitation documented in the infrastructure notes.

**Impact:** Tasks that needed API tokens or credentials (Cloudflare, Home Assistant, Zoho, etc.) failed or produced incomplete results.

**Proposed fix (two-part):**

**Part A: Pre-flight credential injection.** Before dispatching, the orchestrator (running in an interactive session where keychain IS available) should:
1. Scan the task list for tasks that reference known credential-dependent operations.
2. Pre-fetch required secrets from keychain.
3. Inject them as environment variables into the subagent's context, or write them to a temporary file in `/tmp/marathon-secrets-{session_id}/` with restricted permissions (mode 0600).
4. Clean up the secrets file after the task completes.

**Part B: Task-level metadata for credential requirements.** Add a new annotation:

```markdown
- [ ] Deploy crm-worker to Cloudflare
  <!-- model: sonnet -->
  <!-- needs: keychain:Claude Code - DNS, keychain:Claude Code - CF Pages Token -->
```

The orchestrator parses `<!-- needs: keychain:X -->` and handles credential pre-fetch. Tasks with unresolvable credential needs are flagged as blocked before dispatch, not after.

**Part C (quick win): Keychain pre-unlock at marathon start.** Add to the `/marathon` start sequence:

```bash
security unlock-keychain -p "$(security find-generic-password -s 'marathon-keychain-pw' -w)" ~/Library/Keychains/login.keychain-db
```

This unlocks the login keychain once at the start of the marathon while in an interactive session, and it remains unlocked for subagents in the same user session.

---

### Issue 4: Quota Display Shows 0% (Low)

**Observed behavior:** The parent session showed "0% quota, pending first message" despite massive subagent activity. The StatusLine display never updated beyond the initial state.

**Root cause:** Subagent token usage does not flow back to the parent session's API response headers. The StatusLine script reads quota data from the API response's `rate_limits` block, which only reflects the parent session's direct API calls. Since the orchestrator itself makes very few direct calls (it delegates everything to subagents), its reported usage stays near zero.

The server-side `used_percentage` DOES account for all sessions, but this value only appears in API responses to the sessions that make calls. The parent orchestrator session makes few calls, so it rarely receives updated quota data.

**Impact:** The quota monitoring system was effectively blind during the run. Zone transitions were never detected, meaning the throttling and wind-down logic never engaged. Fortunately, quota was not exhausted during this run, but this is a critical gap for the core design promise.

**Proposed fix: Active quota polling.**

Add a periodic quota check that does not depend on StatusLine updates from API responses:

1. **Background poller script** (`scripts/quota-poll.sh`): Runs every 60 seconds as a background process started by `/marathon`. It reads the JSONL files of ALL active subagent sessions (not just the parent), sums their token usage, and writes the aggregated data to the `/tmp/marathon-quota-{session_id}.json` snapshot file.

2. **Subagent JSONL discovery:** The orchestrator records each subagent's transcript path when dispatching. The poller reads these paths to aggregate usage.

3. **Alternative: API probe.** Make a minimal API call from the orchestrator every N minutes solely to receive fresh `rate_limits` headers. This is wasteful but simple and accurate.

4. **Fallback improvement:** Even without active polling, the JSONL fallback in `quota-check.sh` should be enhanced to scan ALL session JSONL files in the Claude sessions directory, not just the parent's transcript. This gives a better cumulative picture.

---

### Issue 5: Manual/Hardware-Blocked Tasks Not Pre-Filtered (Low)

**Observed behavior:** Approximately 12 of 48 tasks (~25%) were blocked on operations that require manual human interaction or access to specific hardware/dashboards:
- Cloudflare dashboard operations (email routing rules, Zero Trust config)
- Zoho dashboard operations (CRM field configuration)
- Xcode on Verve (iOS app builds, signing)
- UniFi console access (network config)
- VoIP.ms portal (phone number porting)

Agents dispatched for these tasks correctly identified the blockers and documented them, but the dispatch was wasted -- the outcome was known before the task started.

**Root cause:** The `/marathon tasks` scanner does not distinguish between "tasks an AI agent can complete autonomously" and "tasks that require human interaction with a specific tool or portal." All items from PROJECT_LOG "Next Steps" sections are treated equally.

**Proposed fix: Blocker classification in task scanning.**

Add a blocker detection pass to `/marathon tasks --scan` and `/marathon tasks --source`:

1. **Keyword-based pre-filter.** Flag tasks containing signals for manual-only work:
   - "dashboard", "console", "portal", "UI", "GUI"
   - "Xcode", "App Store Connect", "TestFlight"
   - "UniFi", "Cloudflare dashboard" (distinct from API-accessible CF operations)
   - "manually", "by hand", "sign in", "log in to"

2. **New task annotation:** `<!-- blocker: manual -->`

   Tasks with this annotation are:
   - Listed in the task file for visibility
   - Skipped during orchestrated dispatch
   - Included in the final summary as "Skipped (manual)"

3. **Interactive review prompt.** After generating the task list, highlight tasks flagged as potentially manual and ask: "These tasks appear to require manual interaction. Include them anyway, or mark as manual-only?"

---

## Watchdog Mechanism: Detailed Proposal

The most critical gap revealed by this first run is the lack of a watchdog for stalled subagents. Here is a detailed design.

### Overview

A background process that monitors all active subagent JSONL files for activity. When a file stops growing (no new bytes written) for a configurable timeout period, the watchdog:

1. Kills the stalled agent process.
2. Marks the task as FAILED with a stall reason.
3. Optionally retries the task with a different model.
4. Logs the incident.
5. Notifies the operator.

### Architecture

```
/marathon --orchestrate
  |
  +-- starts watchdog (background)
  |     |
  |     +-- every 60s: scan active_agents[] JSONL files
  |     |     |
  |     |     +-- if file mtime > STALL_TIMEOUT_MIN:
  |     |           kill agent PID
  |     |           mark task FAILED
  |     |           write to stall log
  |     |           notify operator
  |     |           (optional) retry with different model
  |     |
  |     +-- reads: /tmp/marathon-agents-{session_id}.json
  |     +-- writes: /tmp/marathon-stall-log-{session_id}.jsonl
  |
  +-- dispatches Agent() calls
        |
        +-- registers each agent in /tmp/marathon-agents-{session_id}.json:
              { "task_id": 5, "pid": 12345, "jsonl": "/path/to/session.jsonl",
                "model": "haiku", "started_at": "...", "description": "..." }
```

### Agent Registry: `/tmp/marathon-agents-{session_id}.json`

The orchestrator writes to this file when dispatching each subagent:

```json
{
  "agents": [
    {
      "task_id": 5,
      "pid": 12345,
      "jsonl_path": "/path/to/subagent/session.jsonl",
      "model": "haiku",
      "started_at": "2026-03-22T01:30:00Z",
      "description": "Update CRM worker docs",
      "retry_count": 0
    }
  ]
}
```

When a task completes (or is killed), the orchestrator removes it from the active list.

### Watchdog Script: `scripts/watchdog.sh`

```
#!/usr/bin/env bash
# watchdog.sh -- Monitor subagent JSONL files for stalls.
#
# Usage: watchdog.sh <SESSION_ID> [--stall-timeout 15] [--max-retries 1]
#
# Runs as a background loop. Checks every 60 seconds.
# Kills agents whose JSONL files have not been modified in
# STALL_TIMEOUT minutes.

STALL_TIMEOUT_MIN=15   # default: 15 minutes of no JSONL activity
MAX_RETRIES=1          # default: retry once with a different model
CHECK_INTERVAL=60      # seconds between checks

Loop:
  Read /tmp/marathon-agents-{session_id}.json
  For each agent:
    file_mtime = stat mtime of agent.jsonl_path
    age_min = (now - file_mtime) / 60
    if age_min > STALL_TIMEOUT_MIN:
      1. Send SIGTERM to agent.pid, wait 5s, then SIGKILL if still alive
      2. Append to stall log:
         {"task_id": N, "model": "haiku", "stalled_after_min": age_min,
          "action": "killed", "timestamp": "..."}
      3. Update task file: change `- [ ]` to `- [FAILED]` with
         <!-- error: Agent stalled (no activity for {age_min}m) -->
      4. If agent.retry_count < MAX_RETRIES:
         - Select retry model (if original was haiku, try sonnet; if sonnet, try opus)
         - Write a retry entry to the registry for the orchestrator to pick up
      5. Notify: "Watchdog: Task {N} stalled after {age_min}m, killed.
         {Retrying with sonnet | No retry (max retries reached)}"
      6. Remove agent from active list
  Sleep CHECK_INTERVAL
```

### Model Escalation on Retry

When a stalled agent is retried, the watchdog escalates the model:

| Original Model | Retry Model |
|----------------|-------------|
| haiku          | sonnet      |
| sonnet         | opus        |
| opus           | opus (same) |

The reasoning: a stall on a simpler model may indicate the task was under-resourced. A more capable model might handle edge cases that caused the stall. If opus also stalls, the task is marked FAILED permanently.

### Stall Log: `/tmp/marathon-stall-log-{session_id}.jsonl`

One JSON object per line, appended:

```json
{"task_id":5,"model":"haiku","stalled_min":17,"action":"killed+retry","retry_model":"sonnet","ts":"2026-03-22T02:45:00Z"}
{"task_id":5,"model":"sonnet","stalled_min":20,"action":"killed+failed","ts":"2026-03-22T03:10:00Z"}
```

This log is included in the marathon completion summary and persisted for post-run analysis.

### Integration Points

1. **Orchestrator start:** Launch `watchdog.sh {session_id} &` and record its PID.
2. **Orchestrator dispatch:** Write to the agent registry before each `Agent()` call. This requires the orchestrator to know the subagent's PID and JSONL path, which may not be available until after dispatch. Workaround: register with a placeholder, update once the Agent tool returns initial metadata.
3. **Orchestrator completion:** Kill the watchdog process on clean marathon exit.
4. **Retry handling:** The orchestrator checks the agent registry for retry entries on each loop iteration and dispatches them.

### Open Questions

- **PID discovery:** The Agent tool may not expose the subagent's PID. Alternative: match the JSONL file by creation time and session ID.
- **JSONL path discovery:** Subagent JSONL files are created in Claude's session directory. The orchestrator needs to know where Claude stores these. On macOS, this is typically `~/.claude/projects/*/sessions/*.jsonl`, but the exact path depends on the project and session.
- **Graceful vs. hard kill:** SIGTERM allows the agent to commit WIP. If it is truly stalled, SIGTERM may not work (the process may not be handling signals). A SIGTERM-then-SIGKILL approach is safest.

---

## Additional Proposed Improvements

### 1. Task Duration Estimation

Add estimated duration metadata to tasks:

```markdown
- [ ] Push unpushed commits across all repos
  <!-- model: haiku -->
  <!-- est: 5m -->
```

This enables:
- Better scheduling (fit short tasks into quota gaps)
- Watchdog tuning (a 5-minute task that runs for 30 minutes is more suspicious than a 60-minute task that runs for 30)
- More accurate marathon duration predictions

### 2. Progress Checkpoints Within Tasks

For long-running tasks, the subagent should write periodic progress markers to a known file (`/tmp/marathon-progress-{task_id}.txt`). The watchdog checks this file in addition to the JSONL -- a task that is writing progress but not updating the JSONL is likely busy (e.g., running a long build), not stalled.

### 3. System Resource Monitoring

The orchestrator currently only considers quota zone when deciding parallelism. Add resource monitoring:

```bash
# CPU load average (1-minute)
load=$(sysctl -n vm.loadavg | awk '{print $2}')
# Available memory percentage
mem_free_pct=$(vm_stat | awk '/Pages free/ {free=$3} /Pages active/ {act=$3} /Pages inactive/ {inact=$3} /Pages speculative/ {spec=$3} END {total=free+act+inact+spec; printf "%.0f", (free/total)*100}')
```

If CPU load exceeds core count * 1.5 or available memory drops below 15%, throttle parallelism regardless of quota zone. This prevents OOM kills and system instability during heavy parallel dispatch.

### 4. Dry Run Mode

Add `--dry-run` flag to `/marathon --orchestrate`:

```
/marathon --orchestrate --dry-run
```

This would:
- Parse the task file
- Build dependency tiers
- Assign models
- Print the execution plan (task order, model assignments, estimated parallelism)
- Exit without dispatching

This lets the operator review and adjust before committing to a 10-hour run.

### 5. Post-Run Summary Report

Generate a structured summary at marathon completion:

```markdown
# Marathon Run Summary
Date: 2026-03-22 01:16-11:20 UTC (10h4m)

## Results
- Completed: 33/48 (69%)
- Failed: 3/48 (6%) -- all stalls
- Blocked (manual): 12/48 (25%)

## Model Usage
- Haiku: 30 tasks, ~2.1M tokens
- Sonnet: 12 tasks, ~4.8M tokens
- Opus: 6 tasks, ~3.2M tokens
- Total: ~10.1M tokens (~22% of 5h quota)

## Stall Report
- Task 12 (CRM docs, haiku): stalled at 01:45, killed at 02:00
- Task 18 (archive socialsiphon, haiku): stalled at 02:10, killed at 02:25
- Task 23 (archive imapfilter, haiku): stalled at 02:30, killed at 02:45

## Projects Modified
[list of repos with commit counts]

## Blocked Tasks (Manual Required)
[list with blocker descriptions]
```

This report should be written to `.claude/marathon-report-{date}.md` and committed.

### 6. Task Deduplication

The `/marathon tasks --scan` command can produce duplicate tasks when scanning PROJECT_LOGs and code TODOs that reference the same work. Add deduplication logic that merges tasks with similar descriptions targeting the same project.

### 7. Orchestrator Health Heartbeat

The orchestrator itself could stall (not just subagents). Add a heartbeat file:

```bash
# Written by orchestrator every 5 minutes
echo "$(date +%s)" > /tmp/marathon-heartbeat-{session_id}
```

A separate launchd job or cron entry checks this file and sends an alert if the heartbeat is older than 15 minutes. This catches the case where the entire marathon session dies silently.

---

## Priority Matrix for Fixes

| Fix | Effort | Impact | Priority |
|-----|--------|--------|----------|
| Watchdog mechanism | Medium | Critical | P1 |
| Cross-priority dispatch | Medium | High | P1 |
| Blocker pre-filter in task scanning | Low | Medium | P2 |
| Active quota polling | Medium | High | P2 |
| Keychain pre-unlock at start | Low | Medium | P2 |
| Credential injection metadata | Medium | Medium | P3 |
| Dry run mode | Low | Medium | P3 |
| Post-run summary report | Low | Low | P3 |
| System resource monitoring | Low | Medium | P3 |
| Task duration estimation | Low | Low | P4 |
| Progress checkpoints | Medium | Low | P4 |
| Orchestrator health heartbeat | Low | Low | P4 |
| Task deduplication | Low | Low | P4 |

---

## Conclusion

The first marathon run was a strong validation of the core design. 48 tasks across 35 projects with 14+ parallel agents and zero git conflicts is a significant achievement. The discipline rules, notification pipeline, and task-file-as-shared-state patterns all proved robust.

The critical gaps are all about observability and resilience:
1. **Watchdog** -- the system has no way to detect or recover from stalled agents.
2. **Cross-priority dispatch** -- strict priority ordering creates unnecessary bottlenecks.
3. **Quota visibility** -- the parent session cannot see subagent usage, defeating the core quota monitoring design.

Addressing these three issues (P1 and P2 in the priority matrix) would make the next marathon run significantly more efficient and self-healing. The remaining improvements are optimizations that can be rolled in incrementally.
