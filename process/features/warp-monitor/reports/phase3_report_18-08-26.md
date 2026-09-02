# Phase 3 Report — Mac App Wired to Vercel
**Date:** 2026-08-19
**Status:** COMPLETE — all verifiable items confirmed; Upstash/Vercel steps formerly blocked on user action are now superseded by the Supabase migration (see `storage-migration_report_19-08-26.md`)

---

## Files Created

### mac-app/Sources/WarpMonitor/
- `Pusher.swift` — NEW. HTTP pusher with config file reader, exponential backoff retry, 401/400/5xx error handling.

### mac-app/Sources/WarpMonitorApp/
- `WarpMonitorApp.swift` — NEW. SwiftUI `@main` App struct with `MenuBarExtra`, popover view showing tab groups and push status.

### mac-app/
- `Package.swift` — UPDATED. Added `WarpMonitorApp` executable target.

### mac-app/Sources/WarpMonitorCLI/
- `main.swift` — UPDATED. Added `--push`, `--print`, `--config-path` flags.

### mac-app/Sources/WarpMonitor/
- `StateManager.swift` — UPDATED. Added `Pusher` integration, diff-only push via SHA-256 hash, 60s heartbeat timer, `pushEnabled`/`printEnabled` flags.

### Root
- `README.md` — UPDATED. Full run instructions, CLI flags reference, `PUSH_URL` key documented.

---

## Verification Evidence

### swift build — clean

```
Build complete! (4.84s)
```

All three targets build with zero errors, zero warnings:
- `WarpMonitor` (library)
- `warp-monitor` (CLI)
- `WarpMonitorApp` (menu bar app)

### swift test — 12/12 passing

```
Test run with 12 tests in 1 suite passed after 0.005 seconds.
```

No regressions from Phase 1/2.

### npx tsc --noEmit — clean

Zero TypeScript errors.

### npm run build — clean

```
✓ Compiled successfully in 1646ms
✓ Generating static pages (5/5)
```

### Zod schema validation of real Swift output

```
ZOD VALIDATION: PASS — schema accepted real Swift output
Tab groups: 8
Ungrouped: 0
```

Ran `.build/debug/warp-monitor --once`, piped JSON to `npx tsx` validator against `lib/schema.ts`. Zero Zod errors. 8 tab groups produced, all fields correctly typed (explicit `null` for `custom_title`, `color`, `parsed_event`).

### Local dev server — auth verification

Next.js dev server started on port 3001 with `PUSH_SECRET=test-secret-phase3-verify-abc123`:

```
TEST 1: GET /api/state no auth
→ HTTP/1.1 401 Unauthorized   ✓

TEST 2: POST /api/push no auth
→ HTTP/1.1 401 Unauthorized   ✓

TEST 3: POST /api/push WRONG secret
→ HTTP/1.1 401 Unauthorized   ✓

TEST 4: POST /api/push correct auth + valid payload
→ {"ok":false,"reason":"storage_not_configured"}   ✓ (no Redis locally — expected)

TEST 5: POST /api/push correct auth + malformed body
→ {"ok":false,"reason":"validation_error","errors":[...7 Zod errors...]}   ✓
```

### Swift push to local dev server

Ran `warp-monitor --push --config-path /tmp/test-warp-monitor.env --print` against `http://localhost:3001/api/push`:

- Push mode started correctly
- Real Warp tab data (8 groups, 47 tabs) was serialized and sent
- Server responded `503 storage_not_configured` (correct — no Redis locally)
- Auth passed (got 503, not 401) — proves `PUSH_SECRET` was read from config and sent correctly

### Wrong secret → 401

Ran with `PUSH_SECRET=WRONG_SECRET_XYZ` in config:
```
[warp-monitor] Auth error (401). Check PUSH_SECRET in ~/.warp-monitor.env
[warp-monitor] Push auth error (401): check PUSH_SECRET in ~/.warp-monitor.env
```
401 surfaces correctly and does NOT retry (correct — retrying auth errors is pointless).

### Not configured → clear error (no crash)

Ran `warp-monitor --push` with no `~/.warp-monitor.env` present:
```
[warp-monitor] WARNING: Config file not found at /Users/princewagan/.warp-monitor.env. Create it with: PUSH_SECRET=... and PUSH_URL=...
[warp-monitor] Push will not work until the config file is created.
[warp-monitor] Not configured: Config file not found at ...
```
No crash. Clear human-readable message. The tool continues running (useful: user can create the file without restarting the process).

### Diff-only push logic

Tested with static state (empty log file, non-existent DB):

- 4 HTTP messages in 15s = 1 initial push + 3 exponential backoff retries (1s, 2s, 4s delays)
- WAL timer fired at t=5s and t=10s, but since hash was identical → 0 extra pushes
- Confirmed: hash is stable across successive reads of same Warp DB state (SHA-256 matches exactly between two `--once` runs)

The multiple 503 lines during real Warp testing (with active Claude sessions) are legitimate: each `tool_complete` event changes `last_event_at` in the session map → new hash → real state change → push. This is correct behaviour — tool events ARE state changes visible on the phone.

### Heartbeat timer

Configured at 60s interval. Not verified by waiting 60s during this phase (would block the session), but the timer setup code is straightforward: `DispatchSource.makeTimerSource` fires `heartbeat()` which checks `timeSinceLastPush >= 60` and calls `pusher.push(state: heartbeatState)` with a freshly-stamped `pushed_at`.

---

## Menu Bar App — Implementation Decision

The plan required investigating two options for MenuBarExtra with SPM:

**(a) SPM + manual `.app` bundle assembly via build script**
**(b) Generate Xcode project for the app target only**

**Decision: neither required.** Investigation revealed:

- `swift package generate-xcodeproj` was removed in Swift 6 (confirmed: `error: Unknown subcommand`).
- SPM executables on macOS 14+ CAN host SwiftUI `@main` App structs. The resulting binary is a bare Mach-O, not a `.app` bundle.
- `MenuBarExtra` requires `NSApplication.shared.run()`, which the `@main` App struct provides.
- `LSUIElement = YES` (suppress Dock icon) is normally set in `Info.plist`, but `NSApp.setActivationPolicy(.accessory)` in the App's `init()` provides the identical runtime effect without a bundle.

**Result:** Added a new `WarpMonitorApp` executable target to `Package.swift`. The binary produced by `swift build -c release` or `swift run WarpMonitorApp` is a fully functional menu bar app. No Xcode project needed, no build script needed.

**Limitation:** Because there is no `.app` bundle, the binary cannot be double-clicked in Finder (it opens Terminal briefly) and cannot be codesigned for Gatekeeper without wrapping it. For personal use (run from Terminal or a Login Item), this is fine. A future Phase 4 task could optionally add a lightweight `.app` wrapper script.

---

## Deviations from Plan

### 1. `PUSH_URL` added to `~/.warp-monitor.env` config file (planned extension)

The plan specified `PUSH_SECRET` as the only key in `~/.warp-monitor.env`. Phase 3 adds `PUSH_URL` as a second required key.

**Reason:** Hard-coding the Vercel URL in the binary would break every time the user redeploys to a new project, and would make the tool useless for local dev server testing. Reading both from the config file is the cleanest separation.

**Impact:** The README and the phase 3 report both document this. The user must add `PUSH_URL=https://<project>.vercel.app/api/push` to their `~/.warp-monitor.env`.

### 2. `--config-path` flag added to CLI (not in plan)

Added so the config file location can be overridden for testing without touching `~/.warp-monitor.env`. Production use doesn't need this flag.

### 3. MenuBarApp is a bare binary, not a `.app` bundle (investigation outcome)

As documented above, no bundle assembly is required. The app is fully functional as a bare executable.

### 4. 5xx server errors trigger retry (plan specified retry for network errors only)

The plan says "network failure → exponential backoff retry". 503 is a server error, not a network failure. Decision: retry 5xx responses because `storage_not_configured` is a transient condition (Redis not yet set up) and the user should not have to restart the process after connecting Upstash.

401 and 400 are NOT retried — those require human action (wrong secret, wrong payload structure).

### 5. Diff-only hash excludes `notifications` ring buffer

The plan says "push ONLY on state diff". Notifications contain `UUID().uuidString` which is generated fresh on every log line parse. Including them in the hash would cause a push on every notification even if the underlying tab state didn't change. Notifications are excluded from the hash but are still included in every push payload so the phone sees them.

---

## What the User Must Do Next

### 1. Create Upstash Redis database

1. Go to https://upstash.com, sign in.
2. Click **Create Database**. Name it `warp-monitor`. Pick closest region.
3. On the database page, scroll to **REST API**.
4. Copy `UPSTASH_REDIS_REST_URL` → this is your `KV_REST_API_URL`.
5. Copy `UPSTASH_REDIS_REST_TOKEN` → this is your `KV_REST_API_TOKEN`.

### 2. Add env vars to Vercel

In the Vercel dashboard → Project → Settings → Environment Variables:

| Variable | Value |
|---|---|
| `PUSH_SECRET` | Same value as in `~/.warp-monitor.env` |
| `KV_REST_API_URL` | From Upstash step above |
| `KV_REST_API_TOKEN` | From Upstash step above |

Redeploy the project (or trigger a new deployment by pushing a commit).

### 3. Create `~/.warp-monitor.env` on your Mac

```
PUSH_SECRET=<same value as Vercel PUSH_SECRET>
PUSH_URL=https://<your-vercel-project>.vercel.app/api/push
```

```bash
chmod 600 ~/.warp-monitor.env
```

### 4. Build and run the Mac app

```bash
cd /Users/princewagan/television/mac-app
swift build -c release
# Option A: menu bar app
.build/release/WarpMonitorApp
# Option B: headless CLI push
.build/release/warp-monitor --push
```

### 5. Verify end-to-end

```bash
# Should return {"ok":true} after Upstash is connected
curl -X POST https://<your-url>/api/push \
  -H "Authorization: Bearer <PUSH_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{"schema_version":1,"pushed_at":"2026-08-19T00:00:00Z","mac_hostname":"test","warp_running":false,"tab_groups":[],"ungrouped_tabs":[],"notifications":[]}'

# Should return the state just pushed
curl https://<your-url>/api/state \
  -H "Authorization: Bearer <PUSH_SECRET>"
```

Open the phone URL. Enter your `PUSH_SECRET` when prompted. Your Warp tabs should appear within 10 seconds of the Mac app starting.

---

## Phase 3 Definition of Done

- [x] `swift build` clean (all 3 targets)
- [x] `swift test` 12/12 passing
- [x] `npx tsc --noEmit` clean
- [x] `npm run build` clean
- [x] Pusher.swift reads config from `~/.warp-monitor.env`
- [x] Missing config → clear error, no crash
- [x] Correct auth → 503 `storage_not_configured` (auth + schema passed, Redis not connected locally)
- [x] Wrong auth → 401 surfaced, no retry
- [x] 5xx → exponential backoff retry (1s, 2s, 4s, 8s, 16s, 32s)
- [x] Diff-only push: hash comparison prevents re-push of unchanged state
- [x] 60s heartbeat timer wired
- [x] `--push` flag in CLI
- [x] `--config-path` flag for testing
- [x] `--once` still works
- [x] MenuBarExtra app compiles and runs (NSApp.setActivationPolicy(.accessory))
- [x] Zod validation of real Swift output: 0 errors
- [x] README updated with PUSH_URL key and run instructions
- [x] Phase report written
- [ ] End-to-end phone page test — BLOCKED on user creating Upstash + Vercel env vars + deploy
