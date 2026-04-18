# Marathon Fix Plan — 2026-04-12

Consolidated findings from fresh-eyes code review of coffer, wicket, and infra-console.
Organized by severity, then by project.

---

## Blockers (need user action)

### 1. Wrangler auth on Wiles
- No CF API token with D1/R2/Workers permissions exists in coffer
- Need: `wrangler login` (interactive browser OAuth) or create API token in CF dashboard
- Blocks: D1 seed, R2 audio upload, infra-console deploy

### 2. YouMail export data not on Wiles
- Data is in `~/Downloads/` on Verve — Mutagen only syncs `~/dev/`
- Need: Copy files to `~/dev/youmail-scraper/` on Verve, or SCP directly
- Blocks: D1 seed, R2 audio upload

---

## CRITICAL

### C1. Coffer: Command injection in get.sh (get.sh:39)
`COFFER_KEY` interpolated into `--extract` JSON path without escaping quotes.
Key containing `"` breaks the JSON path and could cause unexpected behavior.
**Fix:** Escape `"` in key before interpolation, or use jq to extract.

### C2. Coffer: Missing `rekey` command (SPEC drift)
SPEC requires `coffer rekey` for re-encrypting after key rotation/compromise.
Only `add-recipient` exists — no way to REMOVE a compromised key.
**Fix:** Implement `lib/rekey.sh` using `sops updatekeys`.

### C3. Coffer: Empty vault file crashes `list` (list.sh:27, common.sh:120)
`github.yaml` is 0 bytes → yq fails with "cannot get keys of !!null".
**Fix:** Check `-s "$vault_file"` before calling yq.

### C4. Infra-console: Service binding null checks missing (index.ts:67-89)
`/kvm/*` and `/spirittrax/*` routes use non-null assertion (`c.env.LAIRKVM!`)
without checking if binding exists. Runtime crash if service not deployed.
**Fix:** Guard with `if (!c.env.BINDING) return c.text('Service unavailable', 503)`.

### C5. Coffer: Default branch is `feat/initial-implementation`
Should be `main`. Confusing for PRs and CI.
**Fix:** `gh repo edit --default-branch main` after renaming.

### C6. Wicket: Socket TOCTOU race condition (daemon.go:189-214)
Between stale state check and `net.Listen()`, attacker could create malicious socket.
**Fix:** Atomic socket creation, verify ownership after listen.

### C7. Wicket: Credential leakage via error messages (all providers)
Failed API calls include full response body in error messages returned to callers.
Could leak tokens/secrets from Cloudflare, GitHub, Tailscale, Zoho APIs.
**Fix:** Sanitize errors — log full response internally, return generic message to callers.

### C8. Wicket: EOF handling bug in audit reader (audit.go:157)
Custom `bytesReader.Read()` returns `fmt.Errorf("EOF")` instead of `io.EOF`.
Breaks json.Decoder EOF detection, could cause infinite loops.
**Fix:** Return `io.EOF`.

---

## HIGH

### H1. Infra-console: CF Access app name mismatch (admin.ts:8)
`ACCESS_APP_NAME = '1507 Infrastructure'` doesn't match actual CF Access app.
/api/admin/emails endpoints non-functional.
**Fix:** Verify actual app name, update constant or use env var.

### H2. Infra-console: Voicemails endpoint not paginated (youmail.ts:23-41)
Returns all records. Could be DoS vector with large datasets.
**Fix:** Add `page`/`limit` params with defaults (50, max 200).

### H3. Infra-console: Conversation messages not paginated (youmail.ts:104-125)
Same issue — all messages returned without limit.
**Fix:** Add limit parameter (default 100, max 500).

### H4. Infra-console: npm vulnerabilities in hono and vite
- Hono ≤4.12.11: 5 moderate/high CVEs (cookie bypass, path traversal, middleware bypass)
- Vite 8.0.0-8.0.4: high severity path traversal
**Fix:** `npm audit fix` and upgrade.

### H5. Coffer: Error message shows empty variable (get.sh:40)
`die "Failed to decrypt: ${value}"` but `value` is unset on failure.
**Fix:** Capture sops stderr separately for error reporting.

### H6. Coffer: Unsafe yq interpolation in import (import.sh:54)
CSV `service` field interpolated into yq path without escaping.
**Fix:** Use `yq --arg svc "$service"`.

### H7. Coffer: categories.yaml out of date
Lists 6 categories but vault has 14.
**Fix:** Update to match actual vault categories.

### H8. Infra-console: Missing FK constraint on text_messages (0004_youmail.sql:53)
No FOREIGN KEY from text_messages.conversation_id → conversations.id.
**Fix:** Add FK with ON DELETE CASCADE.

### H9. Wicket: Audit log write errors silently ignored (daemon.go:340-446)
All `d.auditor.Log()` calls ignore errors. Breaks audit guarantee if disk full.
**Fix:** Check errors, fail request if audit fails.

### H10. Wicket: String credential zeroing is ineffective (provider.go:61-68)
`zeroString()` only zeroes a copy due to Go string immutability.
Original credential memory not wiped.
**Fix:** Use `[]byte` exclusively or memguard library.

### H11. Wicket: PID file race in cmdStop (main.go:152-172)
Reads PID without verifying process is actually wicket. Could SIGTERM wrong process.
**Fix:** Verify process name matches before signaling.

### H12. Wicket: Coffer binary path not absolute (coffer/reader.go:37)
Shells out to `coffer` via PATH — vulnerable to PATH manipulation.
**Fix:** Use absolute path `/usr/local/bin/coffer` or configurable path.

---

## MEDIUM

### M1. Infra-console: Seed script not idempotent (seed-youmail.ts)
Running twice duplicates records. No INSERT OR IGNORE.
**Fix:** Use `INSERT OR REPLACE` or add ON CONFLICT clauses.

### M2. Infra-console: Voicemail folder param not validated (youmail.ts:25-32)
Accepts arbitrary folder values (no security risk due to parameterized query, but unnecessary).
**Fix:** Whitelist valid folder names.

### M3. Infra-console: D1 batch not transactional (bpsmail.ts:226-230)
Reorder endpoint may leave inconsistent sort_order on partial failure.
**Fix:** Verify D1 batch behavior or add error handling.

### M4. Coffer: Clipboard cleanup race condition (get.sh:47)
Background `pbcopy` cleanup may not fire if shell exits before 30s.
**Fix:** Document limitation or use trap.

### M5. Infra-console: Missing test coverage for security boundaries
No tests for: XSS in caller_name/transcript, pagination boundaries, folder validation.
**Fix:** Add security-focused test cases.

### M6. Coffer: Temp file overwrite too small (lock.sh:12)
Only 256 bytes overwritten; age keys can be longer.
**Fix:** Use actual file size or `shred -u`.

### M7. Infra-console: Email validation too loose (admin.ts:144-146)
Only checks for `@`, no length or format validation.
**Fix:** Better regex + max 255 chars.

### M8. Wicket: HTTP response body not size-limited (all providers)
`io.ReadAll()` on API responses without size cap. Malicious API → OOM.
**Fix:** Use `io.LimitReader(resp.Body, 1<<20)`.

### M9. Wicket: Daemonization re-exec uses os.Args[0] (main.go:110)
If binary path is symlinked/controlled, could exec wrong binary.
**Fix:** Use `os.Executable()` instead.

### M10. Wicket: unlock command is TODO stub (main.go:251-257)
`cmdUnlock()` always exits 1. Users can't unlock without restart.
**Fix:** Implement unlock flow.

### M11. Wicket: ntfy topic hardcoded (notify/ntfy.go:17)
Topic `wiles-watchdog-41aa3b5cea50` hardcoded. Not portable.
**Fix:** Move to config file.

---

## LOW (fix opportunistically)

- Coffer: Test coverage gaps (no tests for set, import, edit, lock/unlock, add-recipient)
- Coffer: CSV parser ignores extra fields silently
- Coffer: SPEC mentions identity file but impl uses Keychain
- Infra-console: No CORS headers (intentional? verify)
- Infra-console: No rate limiting on API endpoints
- Infra-console: Inline styles throughout pages/*.ts
- Infra-console: R2 path traversal defense missing URL-encoded check
- Wicket: Test coverage gaps (coffer reader, all providers, ntfy, protocol client)
- Wicket: No startup health check for providers
- Wicket: Connection deadline may not apply to buffered JSON encoding

---

## Already Completed This Session

- [x] Wrangler installed on Wiles (v4.81.1)
- [x] Go installed on Wiles (v1.26.2)
- [x] Wicket binary rebuilt for x86_64
- [x] Wicket daemon installed, configured, running (6 providers, all healthy)
- [x] Wicket launchd plist registered (com.1507.wicket)
- [x] Coffer PR #2 merged (add-recipient)
- [x] Infra-console PR #30 created and merged (YouMail archive)
- [x] Coffer local repo updated to latest

---

## Marathon Session Order

### Phase 1: Criticals (3 projects in parallel)
1a. **Coffer** (C1, C2, C3, C5) — feat/security-fixes branch
1b. **Infra-console** (C4) — feat/service-binding-guards branch
1c. **Wicket** (C6, C7, C8) — feat/security-fixes branch

### Phase 2: Highs
2a. **Infra-console** (H1-H4, H8) — same branch, add pagination + deps
2b. **Coffer** (H5-H7) — same branch, error handling + categories
2c. **Wicket** (H9-H12) — same branch, audit + credential zeroing

### Phase 3: Mediums
3a. **Infra-console** (M1-M3, M5, M7) — seed idempotency, validation, tests
3b. **Coffer** (M4, M6) — clipboard + temp file cleanup
3c. **Wicket** (M8-M11) — response limits, unlock cmd, config

### Phase 4: User unblocks
4a. Wrangler login (interactive)
4b. YouMail data transfer from Verve

### Phase 5: Deploy
5a. Seed D1 with YouMail data
5b. Upload 28 audio files to R2
5c. Deploy infra-console

## Issue Counts

| Project | Critical | High | Medium | Low | Total |
|---------|----------|------|--------|-----|-------|
| Coffer | 3 | 3 | 2 | 4 | 12 |
| Infra-console | 1 | 4 | 5 | 4 | 14 |
| Wicket | 3 | 4 | 4 | 3 | 14 |
| **Total** | **7** | **11** | **11** | **11** | **40** |
