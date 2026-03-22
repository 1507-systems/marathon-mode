# Marathon Mode -- Improvement Implementation Plan

**Date:** 2026-03-22
**Source:** `docs/first-run-retrospective.md` (first overnight run, 48 tasks, ~10 hours)
**Scope:** Six priorities covering resilience, dispatch efficiency, observability, credential handling, task filtering, and mobile approval UX.

---

## Priority 1 -- Agent Watchdog

### Problem

Three Haiku subagents stalled during the first run (no JSONL activity for 5+ hours). The orchestrator had no visibility into stalled agents because it blocks on `Agent()` calls with no timeout. Stalled agents consumed process slots, reducing effective parallelism.

### Design

A background shell script (`scripts/watchdog.sh`) runs alongside the orchestrator. It polls a shared agent registry file for active agents, checks each agent's JSONL transcript file for mtime staleness, and takes corrective action when a stall is detected.

**Detection:** Every 60 seconds, stat the mtime of each registered agent's JSONL file. If `(now - mtime) > STALL_TIMEOUT_MIN` (default: 15 minutes), the agent is considered stalled.

**Response:**
1. SIGTERM the agent PID, wait 5 seconds, SIGKILL if still alive.
2. Mark the task as `- [FAILED]` in the task file with `<!-- error: Agent stalled (no activity for Nm) -->`.
3. Append a structured JSON line to the stall log.
4. Send a push notification via `scripts/notify.sh`.
5. If retry count < MAX_RETRIES (default: 1), write a retry entry to the registry with an escalated model.

**Model escalation on retry:**

| Original | Retry |
|----------|-------|
| haiku    | sonnet |
| sonnet   | opus   |
| opus     | opus (same, then permanent FAILED) |

### Files to Create

**`scripts/watchdog.sh`** (~150 lines)
- Arguments: `<SESSION_ID> [--stall-timeout 15] [--max-retries 1] [--check-interval 60]`
- Reads: `/tmp/marathon-agents-{session_id}.json` (agent registry)
- Writes: `/tmp/marathon-stall-log-{session_id}.jsonl` (stall log, one JSON object per line)
- Modifies: the marathon task file (marks stalled tasks as FAILED)
- Calls: `scripts/notify.sh` for stall alerts

The script runs in an infinite loop, sleeping `CHECK_INTERVAL` between iterations. It exits cleanly on SIGTERM (the orchestrator kills it during wind-down).

Registry file format (`/tmp/marathon-agents-{session_id}.json`):
```json
{
  "agents": [
    {
      "task_id": 5,
      "pid": 12345,
      "jsonl_path": "/path/to/session.jsonl",
      "model": "haiku",
      "started_at": "2026-03-22T01:30:00Z",
      "description": "Update CRM worker docs",
      "retry_count": 0
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

Stall log format (`/tmp/marathon-stall-log-{session_id}.jsonl`):
```json
{"task_id":5,"model":"haiku","stalled_min":17,"action":"killed+retry","retry_model":"sonnet","ts":"2026-03-22T02:45:00Z"}
```

### Files to Modify

**`skills/orchestrate/SKILL.md`**
- Section 4 (Dispatch Loop): Add agent registry write before each `Agent()` dispatch. Register task_id, PID (placeholder until discoverable), JSONL path, model, start time, description, retry_count.
- Section 4: After dispatch loop setup, launch `watchdog.sh {session_id} &` and record its PID in the state file.
- Section 4: On each loop iteration, check the registry's `retries` array for pending retry tasks. Dispatch retries with the escalated model.
- Section 6 (Wind-Down): Kill the watchdog PID on clean exit. Include stall log contents in the final summary.
- Section 7 (Error Handling): Add stall-related failure handling (already partially covered by watchdog, but the orchestrator must handle the case where a watched task returns FAILED).

**`commands/marathon.md`**
- Start subcommand: Add `watchdog_pid` field to the state file schema.
- Stop subcommand: Kill watchdog PID during cleanup. Clean up `/tmp/marathon-agents-*` and `/tmp/marathon-stall-log-*` files.

### Open Questions

1. **PID discovery:** The `Agent()` tool may not expose the subprocess PID. Fallback: match JSONL files by creation time in `~/.claude/projects/*/sessions/*.jsonl`. The watchdog can discover new JSONL files by diffing the session directory listing against known files.
2. **JSONL path discovery:** Subagent sessions create JSONL files in Claude's internal session directory. The orchestrator needs to discover these paths. Options: (a) scan `~/.claude/` for recently-created JSONL files after each dispatch, (b) use the `Agent()` return metadata if it includes a session reference.

### Estimated Complexity

**Medium.** The watchdog script itself is straightforward shell (stat, kill, jq). The harder part is the integration with the orchestrate skill -- the skill is a markdown instruction document, not executable code, so the "agent registry" protocol must be clearly specified as instructions the LLM follows when dispatching.

### Dependencies

None. This is the highest-priority standalone improvement.

---

## Priority 2 -- Aggressive Dispatch (Cross-Priority)

### Problem

The dispatch loop in `skills/orchestrate/SKILL.md` Section 4 iterates priority levels sequentially:

```
For each priority level (1, 2, 3, 4):
  Build dependency tiers from pending tasks at this priority
  For each tier: ...
```

This means P3 and P4 tasks cannot start until ALL P2 tasks complete -- including stalled ones. During the first run, 3 stalled P2 agents blocked all lower-priority work for hours despite the system being in GREEN zone with ample resources.

### Design

Replace the per-priority sequential loop with a global dependency graph. Priority becomes a tie-breaker for dispatch ordering, not a gate.

**New dispatch pseudocode:**

```
1. Build GLOBAL dependency graph across ALL priority levels:
   - Default: tasks in different projects are independent
   - Default: tasks in the same project are sequential (unless <!-- independent -->)
   - Explicit: <!-- after: X --> creates a hard edge from X to this task

2. While pending tasks exist:
   a. Read quota_zone from state file
   b. If RED or ORANGE: wind-down (Section 6) -> STOP
   c. Determine max_parallel from zone:
      - GREEN: unlimited (up to eligible task count)
      - YELLOW: 2
   d. Find all ELIGIBLE tasks (topological sort):
      - All dependencies satisfied (predecessor tasks are [x] or [FAILED])
      - No same-project task currently running (unless <!-- independent -->)
      - Not currently running
      - Not marked [x], [FAILED], or [WIP]
   e. Sort eligible tasks by: priority ASC, then tier within priority ASC
   f. Dispatch up to max_parallel tasks from the sorted eligible list
   g. When any task completes or fails:
      - Update task file
      - Re-evaluate eligibility (new tasks may become unblocked)
      - Check watchdog retry queue
   h. If no eligible tasks and no running tasks: all remaining tasks are blocked -> report and stop
```

**Key behavioral changes:**
- A P4 doc update with no dependencies can run alongside a P1 critical fix.
- A stalled P2 task only blocks tasks that explicitly depend on it (or are in the same project), not all of P3 and P4.
- Priority is still respected: when choosing which N tasks to dispatch from the eligible pool, P1 tasks sort first.

### Files to Modify

**`skills/orchestrate/SKILL.md`**
- Section 2 (Dependency Tier Construction): Rewrite to build a single global dependency graph instead of per-priority-level tiers. The tier concept still exists for ordering within the graph, but tiers are computed globally.
- Section 4 (Dispatch Loop): Replace the nested `For each priority level / For each tier` loop with the flat eligibility-based loop described above.
- Add a new subsection for the eligibility check algorithm.

### Files to Create

None. This is a pure modification to the orchestrate skill document.

### Estimated Complexity

**Medium.** The logic change is conceptually simple (flatten the loop, sort by priority instead of nesting by priority). The complexity is in clearly specifying the dependency graph construction and eligibility rules in natural language instructions that the LLM will follow correctly.

### Dependencies

- Benefits significantly from Priority 1 (Watchdog): stalled agents get killed and marked FAILED, which unblocks dependent tasks faster. Without the watchdog, stalled tasks still block their dependents indefinitely.

---

## Priority 3 -- Quota Visibility

### Problem

The parent orchestrator session showed "0% quota" throughout the entire 10-hour run because subagent token usage does not flow back to the parent session's API response headers. The StatusLine script reads quota data from API responses, but the orchestrator makes very few direct API calls (it delegates everything to subagents). The quota monitoring system was effectively blind.

### Design

Two-part fix: (a) aggregate token usage from subagent JSONL files, and (b) feed the aggregated data into quota-check.sh as a secondary signal.

**Part A: Subagent JSONL aggregation.**

Add logic to `scripts/quota-check.sh` to scan ALL active subagent JSONL files (from the agent registry), not just the parent session's transcript. Sum `output_tokens` across all sessions for a cumulative picture.

The agent registry (from Priority 1) already tracks each subagent's JSONL path. If the watchdog is not yet implemented, fall back to scanning `~/.claude/projects/*/sessions/*.jsonl` for recently-modified files.

**Part B: StatusLine integration.**

Modify `scripts/statusline-quota.sh` to also read the agent registry and include a subagent usage summary in the display string. Example:

```
5h: 42% | 7d: 18% | resets: 2h13m | ZONE: GREEN | task 3/8 | agents: 6 (~2.1M tok)
```

### Files to Modify

**`scripts/quota-check.sh`**
- Add a third data source after the StatusLine cache and single-transcript fallback: "multi-session aggregation" that reads the agent registry and sums tokens from all registered JSONL files.
- Priority: StatusLine cache (fresh) > multi-session aggregate > single-transcript fallback > unknown.
- New argument: optional `--registry /tmp/marathon-agents-{id}.json` to point to the agent registry.

**`scripts/statusline-quota.sh`**
- After building the display string, check for the agent registry file. If it exists, count active agents and sum their token usage. Append `agents: N (~X tok)` to the display.

### Files to Create

None.

### Estimated Complexity

**Medium.** The JSONL parsing is already implemented in quota-check.sh for a single file -- extending it to multiple files is straightforward. The tricky part is ensuring the aggregate doesn't double-count the parent session's own tokens.

### Dependencies

- **Strongly benefits from Priority 1 (Watchdog):** The agent registry provides JSONL paths for all active subagents. Without the watchdog/registry, this improvement must independently discover subagent JSONL files by scanning the filesystem, which is less reliable.

---

## Priority 4 -- Keychain Pre-Unlock

### Problem

Many subagents hit macOS exit code 36 when attempting `security find-generic-password` in headless sessions. The macOS keychain is locked when Claude Code runs as a background process (e.g., via launchd). Tasks that needed API tokens failed or produced incomplete results.

### Design

At marathon start, attempt to unlock the login keychain. If the session is interactive (GUI), this succeeds silently. If headless (launchd), it may fail -- in that case, warn and tag credential-dependent tasks as blocked.

**Pre-unlock step (added to marathon start):**

```bash
# Attempt keychain unlock (interactive sessions only)
security unlock-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null
KEYCHAIN_UNLOCKED=$?
```

If `KEYCHAIN_UNLOCKED != 0`:
1. Log a warning: "Keychain is locked (headless session). Tasks requiring credentials will be tagged as blocked."
2. Scan the task file for tasks that reference known credential-dependent operations (keywords: "deploy", "Cloudflare", "API", "token", "secret", "credential", "authenticate").
3. For matching tasks, append `<!-- blocked: keychain -->` metadata if not already present.
4. The orchestrator skips `<!-- blocked: keychain -->` tasks during dispatch (treated like `<!-- blocked: manual -->`).
5. Report blocked tasks in the notification: "Marathon started. N tasks blocked (keychain locked)."

**Credential-dependent keyword list:**

These keywords in a task description suggest the task may need keychain access:
- "deploy" (usually needs CF API token)
- "Cloudflare", "CF" (API token)
- "Home Assistant", "HA" (HA token)
- "Zoho" (CRM credentials)
- "API key", "API token", "secret", "credential"
- "wrangler" (CF Workers CLI, needs auth)
- "publish" (often involves deployment credentials)

### Files to Modify

**`commands/marathon.md`**
- Start subcommand, Pre-Flight Checks: Add step between existing steps 5 and 6 for keychain pre-unlock attempt.
- Add `keychain_unlocked: true|false` field to the state file schema.

**`skills/orchestrate/SKILL.md`**
- Section 1 (Task File Parsing): Document `<!-- blocked: keychain -->` as a recognized metadata annotation.
- Section 4 (Dispatch Loop): Skip tasks with `<!-- blocked: keychain -->` (same handling as other blocked annotations).

### Files to Create

None.

### Estimated Complexity

**Low.** Single `security unlock-keychain` call at startup, keyword scan of task file, conditional metadata injection. No new scripts needed.

### Dependencies

None. Standalone improvement, though it complements Priority 5 (Manual Task Pre-filter) since both add pre-dispatch blocking annotations.

---

## Priority 5 -- Manual Task Pre-filter

### Problem

Approximately 25% of tasks in the first run (12 of 48) were blocked on operations requiring manual human interaction (Cloudflare dashboard, Xcode, UniFi console, etc.). Agents dispatched for these tasks correctly identified the blockers, but the dispatch itself was wasted compute.

### Design

Add a keyword detection pass during task scanning (`/marathon tasks --scan` and `/marathon tasks --source`) that identifies tasks likely requiring manual interaction and auto-tags them with `<!-- requires: hardware|gui|verve -->`.

The orchestrator skips tasks with `<!-- requires: ... -->` annotations during dispatch and includes them in the final summary as "Skipped (manual)".

**Keyword detection rules:**

| Signal Keywords | Tag |
|----------------|-----|
| "dashboard", "console", "portal", "UI config", "GUI" | `<!-- requires: gui -->` |
| "Xcode", "App Store Connect", "TestFlight", "Simulator" | `<!-- requires: verve -->` |
| "UniFi", "router", "switch config", "VLAN" | `<!-- requires: gui -->` |
| "hardware", "physical", "plug in", "cable", "install device" | `<!-- requires: hardware -->` |
| "manually", "by hand", "sign in to", "log in to" | `<!-- requires: gui -->` |
| "Verve", "desktop app" | `<!-- requires: verve -->` |
| "screenshots", "screen recording" | `<!-- requires: gui -->` |

**Behavior in task scanning:**

After generating the task list, run the keyword scan. For each match:
1. Append the appropriate `<!-- requires: ... -->` annotation.
2. In interactive mode: highlight these tasks and ask "These tasks appear to require manual interaction. Include them for dispatch, or mark as manual-only?"
3. In non-interactive mode (scan/source): auto-tag silently.

**Behavior in orchestrator:**

Tasks with `<!-- requires: ... -->` are:
- Listed in the task file for visibility and tracking.
- Skipped during dispatch (treated as permanently blocked for this run).
- Reported in the wind-down summary as "Skipped (manual): N tasks".

### Files to Modify

**`commands/marathon.md`**
- Tasks subcommand (`--scan` and `--source` modes): Add a post-generation keyword scan step. After building the task list, iterate all `- [ ]` lines and check descriptions against the keyword table. Append annotations for matches.

**`skills/orchestrate/SKILL.md`**
- Section 1 (Task File Parsing): Document `<!-- requires: hardware|gui|verve -->` as a recognized annotation.
- Section 4 (Dispatch Loop): Add eligibility filter -- tasks with `<!-- requires: ... -->` are never dispatched.
- Section 6 (Wind-Down): Include skipped-manual count in the summary.

### Files to Create

None.

### Estimated Complexity

**Low.** Keyword matching against task description strings, annotation injection. The keyword list is static and can be maintained as a simple array in the skill document.

### Dependencies

None. Standalone, but shares pattern with Priority 4 (both add pre-dispatch blocking annotations).

---

## Priority 6 -- Docs Portal Approve Button (Mobile Fix)

### Problem

The approve button at `docs.1507.cloud` does not work on mobile browsers. Marathon overnight runs check `docs.1507.cloud/api/approval/<project>` before executing plans -- if the approval flow is broken on mobile, the operator cannot approve plans while monitoring from a phone.

### Design

Investigate and fix the approval flow for mobile browsers. This requires examining the docs-viewer codebase (separate project at `~/Library/Mobile Documents/com~apple~CloudDocs/Developer/docs-viewer/`).

**Investigation steps:**

1. Read the docs-viewer source to understand the approval button implementation.
2. Test the approval endpoint from a mobile user-agent using browser automation or curl.
3. Identify the failure mode: is it a JavaScript issue, a CSS/touch target issue, a CORS issue, or an API authentication issue?
4. Fix the root cause.

**Likely failure modes (in order of probability):**

1. **Touch event handling:** Button may use `onclick` but not handle `touchstart`/`touchend` properly on iOS Safari.
2. **Viewport/CSS:** Button may be hidden, overlapped, or off-screen on small viewports.
3. **JavaScript error:** A script dependency may fail to load on mobile.
4. **Authentication:** The approval endpoint may require a cookie or header that mobile browsers don't send.

### Files to Modify

**Located in the `docs-viewer` project** (not marathon-mode):
- The approval button component/page (path TBD after investigation).
- The approval API endpoint handler (path TBD).

### Files to Create

None expected, but may need a test script.

### Estimated Complexity

**Low-Medium.** Depends on the root cause. A CSS fix is trivial; a JS event handling fix is low effort; an authentication issue may require more work.

### Dependencies

- This is in a **separate project** (`docs-viewer`), not in marathon-mode.
- Does not depend on any other priority in this plan.
- However, it affects marathon operations: without mobile approval, the operator cannot approve plans during overnight monitoring.

---

## Implementation Order

The priorities are designed to be implementable in order, with earlier improvements enabling later ones:

```
Priority 1 (Watchdog)
    |
    +---> Priority 2 (Cross-Priority Dispatch) -- benefits from watchdog killing stalled tasks
    |
    +---> Priority 3 (Quota Visibility) -- benefits from agent registry for JSONL discovery

Priority 4 (Keychain Pre-unlock) -- standalone
Priority 5 (Manual Pre-filter) -- standalone
Priority 6 (Docs Portal Fix) -- standalone, separate project
```

Priorities 4, 5, and 6 are independent and can be implemented in any order or in parallel with 1-3.

### Estimated Total Effort

| Priority | Effort | Files Created | Files Modified |
|----------|--------|---------------|----------------|
| P1 Watchdog | Medium | 1 (`scripts/watchdog.sh`) | 2 (`skills/orchestrate/SKILL.md`, `commands/marathon.md`) |
| P2 Cross-Priority | Medium | 0 | 1 (`skills/orchestrate/SKILL.md`) |
| P3 Quota Visibility | Medium | 0 | 2 (`scripts/quota-check.sh`, `scripts/statusline-quota.sh`) |
| P4 Keychain | Low | 0 | 2 (`commands/marathon.md`, `skills/orchestrate/SKILL.md`) |
| P5 Manual Pre-filter | Low | 0 | 2 (`commands/marathon.md`, `skills/orchestrate/SKILL.md`) |
| P6 Docs Portal | Low-Medium | 0 | TBD (in docs-viewer project) |

### Additional Improvements (Not Prioritized Here)

The retrospective also proposed several lower-priority improvements that are not included in this plan but should be tracked for future work:

- **Dry run mode** (`--dry-run` flag for `/marathon --orchestrate`)
- **Post-run summary report** (structured markdown at marathon completion)
- **System resource monitoring** (CPU/memory throttling alongside quota)
- **Task duration estimation** (`<!-- est: 5m -->` metadata)
- **Progress checkpoints** (subagent progress markers for long tasks)
- **Orchestrator health heartbeat** (detect parent session stalls)
- **Task deduplication** (merge duplicate tasks from scan)

These can be added incrementally after the six priorities in this plan are complete.
