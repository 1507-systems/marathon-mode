---
description: "Build a prioritized task list for marathon execution"
argument-hint: "[--source path] [--scan]"
allowed-tools: Bash, Read, Write, Glob, Grep, Agent
---

# /marathon-tasks — Build a Task List

Generate a prioritized task list for marathon execution. The output is always a markdown checklist at `.claude/marathon-tasks.md` (or a user-specified path).

## Modes

### `--scan` — Scan Working Directory

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

### `--source <path>` — Parse a Projects File

Read a structured projects file (like a `projects.md`) and extract actionable items:

1. Parse project entries — look for status indicators (🟡, "pending", "needs", "TODO", "known issues")
2. Extract actionable items from each project's description
3. Prioritize based on status severity
4. Auto-assign model hints based on task complexity
5. Group by project with dependency hints (`<!-- after: ... -->` for same-project sequential tasks)

### No Arguments — Interactive

1. Ask: "What would you like to work on? I can help prioritize and build a task list."
2. Have a conversation to understand priorities
3. Build the list collaboratively

## Output Format

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

## After Generation

Always present the generated list to the user:
- Show the full task list
- Ask: "Does this look right? You can edit the file directly or tell me what to change. When ready, run `/marathon` to start."
