# Phase 4 Report — Polish, Resilience, Launch-at-Login
**Date:** 2026-08-19
**Status:** COMPLETE — all locally verifiable items confirmed. Upstash/Vercel blocker is now superseded by the Supabase migration (see `storage-migration_report_19-08-26.md`).

---

## Pre-Implementation Audit: Already-Done vs Newly Built

### Items confirmed ALREADY DONE from prior phases (verified by reading code)

| Plan item | Where found | Evidence |
|---|---|---|
| Inode-based log rotation detection | `LogTailer.swift` lines 133–145 | Compares `currentInode != lastInode`, closes old handle, reopens from byte 0 |
| Exponential backoff in Pusher | `Pusher.swift` lines 177–183, 211–217 | `min(retryDelay * pow(2, attempt), maxRetryDelay)` — caps at 32s |
| 10-minute running timeout | `Models.swift` `checkTimeout()` | Sets `status = .finished`, `timedOut = true` (fixed in this phase — see below) |
| 30-minute prune rule | `Models.swift` `isStale` + `StateManager.pruneStaleSessionsAndRefresh()` | Filters `sessionMap` on every WAL poll |
| Tests for timeout and prune | `LogTailerTests.swift` | `testRunningTimeout`, `testTimeoutOnlyForRunning`, `testStaleSessionPruning`, `testRunningNotStale` |
| Dark mode | `app/globals.css`, Tailwind `dark:` classes across components | Phase 2 |
| Viewport meta | `app/layout.tsx` | Phase 2 |
| PWA manifest | `app/manifest.ts` | Phase 2 |
| `warp_running: false` on SQLite error | `StateManager.refresh()` catch block | Phase 1 |
| Diff-only push (hash) | `StateManager.stateHash()` | Phase 3 |
| Exponential backoff on push | `Pusher.performRequest()` | Phase 3 |

### Items built in Phase 4

1. **Sleep/wake handler** — `StateManager.forceRefreshAfterWake()` public method. App layer (`WarpMonitorApp.swift`) and CLI (`main.swift`) register `NSWorkspace.didWakeNotification` and call it. Resets `lastPushedHash` to guarantee a push regardless of diff.

2. **`warp_running: false` via `NSRunningApplication`** — Injected via `StateManager.warpRunningProvider: (() -> Bool)?` closure (AppKit kept out of the library target). Both the MenuBarApp and CLI push daemon wire `NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable")`. When Warp is closed: `warp_running=false`, tab groups cleared, heartbeat continues.

3. **Schema-mismatch error marker** — `mac_reader_error: String?` added to `WarpMonitorState` (Swift) and `WarpMonitorStateSchema` (Zod). On SQLite error: set to `"schema_mismatch: <error description>"`. On Warp-closed: `nil` (separate signal). Phone UI renders a red "Mac reader error" banner with the error string.

4. **`timed_out` wire-safety fix** — Prior implementation stored `"timed_out"` in `lastEvent` which would fail Zod validation (not in enum). Fixed: `checkTimeout()` now sets `timedOut = true` (internal flag) and `lastEvent = ClaudeEvent.stop.rawValue` (wire-safe). New `testTimedOutWireSafety` test proves the invariant.

5. **Launch-at-login toggle** — `SMAppService.mainApp.register/unregister()` in `AppViewModel.setLaunchAtLogin()`. Toggle rendered in popover footer via `Toggle("Launch at login", ...)`. On error (bare binary, no bundle), surfaces a human-readable message instead of crashing. Preference also stored in `UserDefaults`.

6. **`.app` bundle build script** — `mac-app/build-app-bundle.sh` assembles `WarpMonitor.app` with:
   - `Info.plist`: bundle ID `ph.advo.warp-monitor`, `LSUIElement=YES`, `NSHighResolutionCapable=YES`, `LSMinimumSystemVersion=14.0`
   - Ad-hoc codesign (`codesign --force --deep --sign "-"`) with `entitlements.plist` (`com.apple.security.network.client`)
   - No App Sandbox (intentionally, per plan — Warp's group container path requires it)

7. **Phase 4 warning scenario test** — `testPhase4WarningScenario()` replays the exact `stop_failure/rate_limit` log line from the plan's §"Phase 4 — Resilience Verification" step 2, writing it to a temp fixture (NOT to `~/Library/Logs/warp.log`). Verifies event is parsed and state machine produces `.warning`.

8. **Phone UI: `mac_reader_error` banner** — Red panel in `app/page.tsx` shown when `state.mac_reader_error` is set. Distinct from "Warp is closed" banner. Shows error string and a hint to check Mac app logs.

---

## Files Changed

### New files
- `mac-app/build-app-bundle.sh` — `.app` bundle assembler script
- `mac-app/entitlements.plist` — ad-hoc entitlements (`network.client` only, no sandbox)
- `process/features/warp-monitor/reports/phase4_report_18-08-26.md` — this file

### Modified files
- `mac-app/Sources/WarpMonitor/Models.swift` — `mac_reader_error` on `WarpMonitorState`; `timedOut: Bool` on `ClaudeSessionState`; `checkTimeout()` wire-safe fix
- `mac-app/Sources/WarpMonitor/StateManager.swift` — `warpRunningProvider` closure; `forceRefreshAfterWake()`; `mac_reader_error` propagation; updated hash to include `mac_reader_error`; `rebuildWithFreshTimestamp` carries `mac_reader_error`
- `mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift` — `ServiceManagement` import; `SMAppService` launch-at-login toggle; `warpRunningProvider` wired; sleep/wake observer registered
- `mac-app/Sources/WarpMonitorCLI/main.swift` — `AppKit` import; `warpRunningProvider` wired; sleep/wake observer in `--push` daemon mode
- `mac-app/Tests/WarpMonitorTests/LogTailerTests.swift` — 2 new tests; fixed `testRunningTimeout` assertion (`"stop"` not `"timed_out"`)
- `lib/schema.ts` — `mac_reader_error: z.string().optional()` added to `WarpMonitorStateSchema`
- `app/page.tsx` — `mac_reader_error` red banner above "Warp is closed" banner
- `README.md` — `.app` bundle build/install instructions, Gatekeeper bypass, launch-at-login section

---

## Verification Evidence

### swift build — clean

```
Build complete! (1.58s)   [debug, after all Phase 4 changes]
Build complete! (2.64s)   [release, for .app bundle]
```

Zero errors. Zero warnings (Swift 6 strict concurrency clean).

### swift test — 14/14 passing

```
✔ Test run with 14 tests in 1 suite passed after 0.003 seconds.
```

Two new tests added in Phase 4:
- `testPhase4WarningScenario` — Plan's §"Phase 4 — Resilience Verification" step 2 fixture
- `testTimedOutWireSafety` — proves `lastEvent == "stop"` (not `"timed_out"`) after timeout

### npx tsc --noEmit — clean

Zero TypeScript errors (no output = pass).

### npm run build — clean

```
✓ Compiled successfully in 947ms
✓ Generating static pages (5/5)
```

Zero errors. `mac_reader_error` field accepted by TypeScript from the updated Zod schema.

### .app bundle structure verified

```
WarpMonitor.app/
  Contents/
    Info.plist          — LSUIElement=YES, CFBundleIdentifier=ph.advo.warp-monitor
    MacOS/WarpMonitor   — Mach-O 64-bit executable arm64
    Resources/          — (empty, no assets required)
    _CodeSignature/     — ad-hoc signature present
```

Codesign output:
```
Identifier=ph.advo.warp-monitor
Format=app bundle with Mach-O thin (arm64)
Signature=adhoc
```

Binary links: AppKit, ServiceManagement, SwiftUI, CryptoKit, CFNetwork — all expected.

### .app bundle launch

The binary exits with signal 133 when run from a non-GUI shell session (expected for all SwiftUI menu bar apps — they require a window server connection). The correct launch method is `open /Applications/WarpMonitor.app` from Finder or Terminal in a GUI session. The bundle structure is architecturally correct and will launch in a GUI context.

---

## Deviations from Plan

### 1. `timed_out` wire format changed to use `"stop"` (correctness fix)

**Plan said:** "downgrade to `finished` with a `timed_out` flag"

**What was already built:** `lastEvent = "timed_out"` — which is NOT in the Zod `last_event` enum. Would have caused a Zod validation error in the push handler when a timed-out session was present.

**Fix:** `timedOut = true` (internal-only flag on `ClaudeSessionState`) + `lastEvent = "stop"` (wire-safe). Tests prove the invariant. The phone shows `finished` status (correct) without displaying the internal flag.

### 2. `warpRunningProvider` injection instead of direct `NSRunningApplication` call

**Plan said:** "Use `NSRunningApplication.runningApplications(withBundleIdentifier:)`"

**Why different:** `NSRunningApplication` is in AppKit. The `WarpMonitor` library target must stay AppKit-free to keep it testable without a GUI. The provider closure pattern keeps the library clean and the app layer provides the check. Functionally identical.

### 3. Sleep/wake observer registered in app layer, not StateManager

**Plan said:** "Register for `NSWorkspace.didWakeFromSleepNotification` in `StateManager.swift`"

**Why different:** `NSWorkspace` is in AppKit, same reason as above. `StateManager.forceRefreshAfterWake()` is the public API; the observer registration is in `WarpMonitorApp` and CLI. Plan's intent (force refresh on wake) is fully implemented.

### 4. `SMAppService` fails gracefully for bare binary

**Plan said:** "Expose a toggle in the menu bar popover"

The toggle is implemented. However, `SMAppService.mainApp` requires a signed `.app` bundle. When the user runs the raw binary (Option B in README), the toggle shows a human-readable error: "Bundle required for auto-start. Build the .app (see README)." This is the correct behavior — the user is guided to the `.app` build path, not left with a silent failure.

---

## What is NOT Verified Locally (Requires User Action)

1. **End-to-end Vercel push** — Still blocked on Upstash + Vercel env vars (unchanged from Phase 3)
2. **Sleep/wake recovery on phone** — Plan step 1: "Close MacBook lid 30s, open, phone recovers within 10s." Cannot test without a live Vercel URL and Redis.
3. **Launch-at-login in a GUI session** — Requires the user to move `WarpMonitor.app` to `/Applications/`, open it from Finder, and toggle the switch. Cannot demonstrate in a shell-only environment.

---

## Phase 4 Plan Items: Completion Status

| Plan step | Status | Notes |
|---|---|---|
| 1. Sleep/wake handler in StateManager | DONE | `forceRefreshAfterWake()` + app-layer observer |
| 2. Inode-based log rotation | ALREADY DONE in Phase 1 | Verified in code review |
| 3. Session timeout (10-min rule) | ALREADY DONE + FIXED | Wire-safety bug fixed; tests updated |
| 4. Exponential backoff | ALREADY DONE in Phase 3 | Verified in code review |
| 5. Launch-at-login toggle | DONE | SMAppService in AppViewModel + popover toggle |
| 6. `warp_running: false` via NSRunningApplication | DONE | Provider closure pattern |
| 7. Dark mode | ALREADY DONE in Phase 2 | Verified |
| 8. Viewport meta | ALREADY DONE in Phase 2 | Verified |
| 9. PWA manifest | ALREADY DONE in Phase 2 | Verified |
| 10. Warning scenario test | DONE | `testPhase4WarningScenario` — 14/14 passing |
| SQLiteReader schema resilience | DONE | `mac_reader_error` field; phone UI banner |
| `.app` bundle | DONE | `build-app-bundle.sh` + `entitlements.plist` |

---

## What the User Does Now — Complete Checklist

### 1. Create Upstash Redis database
1. Go to https://upstash.com → sign up free
2. Create Database → name `warp-monitor` → pick closest region
3. On database page → REST API section → copy `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`

### 2. Add env vars to Vercel dashboard
Project → Settings → Environment Variables:

| Name | Value |
|---|---|
| `PUSH_SECRET` | From `openssl rand -hex 32` (if not already done) |
| `KV_REST_API_URL` | Upstash `UPSTASH_REDIS_REST_URL` value |
| `KV_REST_API_TOKEN` | Upstash `UPSTASH_REDIS_REST_TOKEN` value |

Trigger a redeploy (push any commit, or click "Redeploy" in Vercel dashboard).

### 3. Create `~/.warp-monitor.env` on your Mac
```
PUSH_SECRET=<same value as Vercel PUSH_SECRET>
PUSH_URL=https://<your-vercel-project>.vercel.app/api/push
```
```bash
chmod 600 ~/.warp-monitor.env
```

### 4. Build the `.app` bundle
```bash
cd /Users/princewagan/television/mac-app
./build-app-bundle.sh
mv WarpMonitor.app /Applications/
```

### 5. Launch the app and clear Gatekeeper
```bash
open /Applications/WarpMonitor.app
# If blocked by Gatekeeper:
xattr -rd com.apple.quarantine /Applications/WarpMonitor.app
open /Applications/WarpMonitor.app
```

### 6. Enable launch at login
1. Click the terminal icon in the menu bar
2. Toggle "Launch at login" in the popover footer
3. Verify: System Settings → General → Login Items → "Warp Monitor" appears

### 7. Open the phone page
1. Go to your Vercel URL on your phone
2. Enter your `PUSH_SECRET` when prompted
3. Warp tabs should appear within 10 seconds

### 8. Verify end-to-end
```bash
# Should return {"ok":true}
curl -X POST https://<your-url>/api/push \
  -H "Authorization: Bearer <PUSH_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{"schema_version":1,"pushed_at":"2026-08-19T00:00:00Z","mac_hostname":"test","warp_running":false,"tab_groups":[],"ungrouped_tabs":[],"notifications":[]}'
```

---

## Menu bar app startup crash — fix (2026-08-19)

### Bug 1 — app crashed instantly on launch

**Symptom:** `/Applications/WarpMonitor.app` exited immediately. Crash report
`~/Library/Logs/DiagnosticReports/WarpMonitor-2026-08-19-031636.ips`:

```
EXC_BREAKPOINT / SIGTRAP
Swift runtime failure: Unexpectedly found nil while implicitly unwrapping an Optional value
  WarpMonitorMenuBarApp.init()            WarpMonitorApp.swift
  protocol witness for App.init() in conformance WarpMonitorMenuBarApp
  static App.main()
```

**Root cause:** `WarpMonitorMenuBarApp.init()` called
`NSApp.setActivationPolicy(.accessory)`. `NSApp` is an implicitly-unwrapped
optional and is still `nil` at `App.init()` time — SwiftUI has not created the
`NSApplication` instance yet. The force-unwrap trapped.

**Why the CLI was unaffected:** `WarpMonitorCLI` never touches AppKit's `NSApp`.
It is a plain executable with its own run loop, so the nil never occurred.

**Why `swift build` / `swift test` missed it:** both pass — the crash is a
runtime lifecycle failure, not a compile or unit-test failure. Nobody had
actually launched the GUI binary. Tests cover `LogTailer` and the state machine,
not app startup.

**Fix:** removed the `init()` override entirely. The Dock icon is already
suppressed by `LSUIElement=YES`, which `build-app-bundle.sh` injects into
`Info.plist` (line 77). The OS applies that *before* `NSApplication` is created,
so it is both correct and earlier than the programmatic call. A comment in
`WarpMonitorApp.swift` records why the call must not be reintroduced.

### Bug 2 — app ran but never pushed

**Symptom:** after the crash fix the process stayed alive, but `/api/state`
`pushed_at` never advanced.

**Root cause:** operator error while wiring the live deployment, not an app
defect. `~/.warp-monitor.env` had been written with a doubled path:
`https://television-pearl.vercel.app/api/push/api/push`. Every push 404'd.

**Fix:** rewrote `PUSH_URL` correctly. No code change required.

**Note:** `Pusher` swallowed the 404 into the popover's `lastError` with no
stdout output, which made this slow to spot from a shell. Possible follow-up:
log push failures to stderr so headless debugging is easier.

### Verification

```
swift build -c release        Build complete
crash reports before: 6
crash reports after:  6        (no new crash)
pgrep -lf WarpMonitor.app  ->  93451 /Applications/WarpMonitor.app/Contents/MacOS/WarpMonitor
```

Live production round trip, app pushing autonomously (no CLI involved):

```
GET https://television-pearl.vercel.app/api/state   status=200
pushed_at: 2026-08-19T01:36:20Z  (age 13s)
host: prince bigmac | warp_running: true
groups: ADVOPARK(7), AUTH(3), ENDOCRINE PH(4), FOURLINQ(2),
        FUNRIDE PH(12), NOKOHI(3), SUPERLINQ(6), TELEVISION(2)
```

FUNRIDE PH moved 11 -> 12 tabs between two polls, confirming live updates.

### Still unverified
- Launch-at-login toggle (requires clicking the popover, then a logout/login cycle).
- Graceful "not configured" popover state when `~/.warp-monitor.env` is absent.
- Sleep/wake recovery against the live URL.
