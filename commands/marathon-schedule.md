---
description: "Generate and install scheduler configs for automated marathon runs"
argument-hint: "[--platform auto|macos|linux|cron] [--start HH:MM] [--stop HH:MM] [--days weekdays|daily] [--regenerate] [--uninstall]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit
---

# /marathon-schedule — Schedule Automated Runs

Generate platform-native scheduler configs for automated marathon sessions.

## Steps

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
