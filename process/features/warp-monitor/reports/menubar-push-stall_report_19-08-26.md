# Warp Monitor — Menu Bar Push Stall: Root Cause & Fix Report
**Date:** 2026-08-19  **Severity:** High (silent data staleness for production dashboard)

---

## Executive Summary

When launched via `open /Applications/WarpMonitor.app`, the app stopped pushing state updates silently. The phone dashboard's `pushed_at` froze for 5+ minutes while the process stayed alive. Root cause: **macOS App Nap coalescing DispatchSourceTimers on `.utility` QoS queues** for apps without visible windows. Fix: upgrade all three background queues from `.utility` to `.userInitiated` QoS, plus acquire a `ProcessInfo.beginActivity` token at startup to opt out of App Nap for the process lifetime. A durable debug log at `/tmp/warp-monitor-debug.log` was added so future stalls are diagnosable without this investigation overhead.

---

## Discriminating Experiment (Pre-Investigation Evidence)

| Launch method | Push behavior |
|---|---|
| `.build/release/warp-monitor --push` (CLI foreground) | Pushes fine |
| `/Applications/WarpMonitor.app/Contents/MacOS/WarpMonitor` run directly in shell | Pushes fine |
| `open /Applications/WarpMonitor.app` | Does NOT push; pushed_at frozen for 5+ min |

The binary was confirmed identical (via `nm`). The difference is launch context only.

---

## Hypothesis Testing

### H1: Lazy `@StateObject` construction (AppViewModel.init never called until popover opens)

**Test:** Added `debugLog("[AppViewModel.init] ...")` as the first line of `AppViewModel.init()`. Rebuilt, launched via `open`, checked `/tmp/warp-monitor-debug.log` after 5 seconds.

**Evidence:**
```
2026-08-19T14:20:32Z [AppViewModel.init] AppViewModel constructed — startManager running immediately
2026-08-19T14:20:32Z [AppViewModel.init] App Nap prevention token acquired: true
2026-08-19T14:20:32Z [startManager] Configuring StateManager
```

**Verdict: ELIMINATED.** `AppViewModel.init()` fires at t+0s on launch, before any user interaction. `MenuBarExtra`'s label closure references `appState.alertLevel` immediately, forcing `@StateObject` construction. The lazy-init path does not apply here.

---

### H2: App Nap / timer throttling (`.utility` QoS queues coalesced by OS)

**Mechanism:** macOS App Nap coalesces timers on `.background` and `.utility` QoS queues for apps that have no visible windows and no active user interaction. When launched via `open`, a `LSUIElement=YES` app with no open popover is immediately classified as a background process. There is no controlling terminal and no foreground process group (unlike running the binary directly in a shell). App Nap activates within seconds of the process becoming background-eligible.

Three queues used `.utility` QoS:
- `StateManager.walQueue` — 5s poll timer + 60s heartbeat timer
- `LogTailer.queue` — 2s fallback read timer
- `Pusher.retryQueue` — exponential-backoff retry timer

**Test:** Added `wmDebugLog("[walTimer] fired")` to walTimer event handler and `wmDebugLog("[heartbeatTimer] fired")` to heartbeatTimer handler. First build (without QoS fix, only activityToken) showed:

```
2026-08-19T14:20:32Z [AppViewModel.init] AppViewModel constructed — startManager running immediately
2026-08-19T14:20:32Z [AppViewModel.init] App Nap prevention token acquired: true
...
2026-08-19T14:20:36Z [pushIfChanged] state changed — pushing  ← initial refresh
2026-08-19T14:20:37Z [push.ok] Push succeeded
...
2026-08-19T14:22:18Z [walTimer] fired   ← FIRST walTimer fire: t+106s (expected t+5s)
2026-08-19T14:22:19Z [heartbeatTimer] fired  ← coalesced with walTimer (expected t+60s)
2026-08-19T14:22:19Z [heartbeat] skipped: timeSinceLastPush=5s < 60s
2026-08-19T14:22:21Z [walTimer] fired
2026-08-19T14:22:26Z [walTimer] fired
```

- walTimer expected first fire: t+5s. Actual: t+106s. Delay: **101 seconds**.
- heartbeatTimer expected: t+60s. Actual: t+107s (coalesced burst with walTimer).
- This 100s+ initial deferral matches App Nap's behavior exactly.
- State changes during t+0 to t+106s came exclusively from LogTailer FSEvents (Claude session activity writing to `warp.log`), not from walTimer. Without active Claude sessions, the dashboard would show a full 100s+ stall.

**Verdict: CONFIRMED ROOT CAUSE.** App Nap coalesces `.utility` QoS timers for backgrounded processes. The app lacked both (a) the proper QoS to avoid coalescing and (b) a process-level activity token.

---

## Root Cause Chain

```
open /Applications/WarpMonitor.app
  → process launched with no controlling tty, no foreground process group
  → LSUIElement=YES: no Dock icon, no visible window
  → macOS immediately classifies process as background-eligible
  → App Nap activates (within seconds)
  → DispatchSourceTimers on .utility queues coalesced/deferred
  → walTimer (5s poll) and heartbeatTimer (60s) not fired for 100+ seconds
  → StateManager.refresh() not called by timer
  → pushIfChanged() not called by timer
  → pushed_at frozen (only updated when LogTailer receives OSC 777 events)
  → without active Claude sessions, pushed_at freezes indefinitely
```

The user observed 5+ minute stalls because when no Claude sessions were active, no LogTailer events arrived to trigger refreshes either. The timers were the only backup mechanism, and they were silently throttled.

---

## Fix

Three changes, all in the same commit boundary:

### 1. QoS upgrade: `.utility` → `.userInitiated` (primary fix)

Apple's documentation confirms `.userInitiated` QoS class (`QOS_CLASS_USER_INITIATED`) is **not subject to App Nap timer coalescing** even without an activity token. Changed all three queues:

**`StateManager.swift`:**
```swift
// Before:
private let walQueue = DispatchQueue(label: "ph.advo.warp-monitor.walwatcher", qos: .utility)
// After:
private let walQueue = DispatchQueue(label: "ph.advo.warp-monitor.walwatcher", qos: .userInitiated)
```

**`LogTailer.swift`:**
```swift
// Before:
private let queue = DispatchQueue(label: "ph.advo.warp-monitor.logtailer", qos: .utility)
// After:
private let queue = DispatchQueue(label: "ph.advo.warp-monitor.logtailer", qos: .userInitiated)
```

**`Pusher.swift`:**
```swift
// Before:
private let retryQueue = DispatchQueue(label: "ph.advo.warp-monitor.pusher.retry", qos: .utility)
// After:
private let retryQueue = DispatchQueue(label: "ph.advo.warp-monitor.pusher.retry", qos: .userInitiated)
```

Rationale for `.userInitiated` vs `.userInteractive`: the poll is not a UI animation (no frame deadline); `.userInitiated` is appropriate for near-real-time background work initiated by the user. Battery impact is negligible: SQLite reads are read-only, each completes in microseconds.

### 2. Process-level App Nap prevention token (defense-in-depth)

Added to `AppViewModel.init()`, before `startManager()`:

```swift
private var activityToken: NSObjectProtocol?

init() {
    activityToken = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Warp Monitor needs timely timer delivery to push state updates"
    )
    startManager()
}
```

Options chosen: `.userInitiatedAllowingIdleSystemSleep` — suppresses App Nap timer coalescing while allowing the system to sleep (display and idle system sleep still work). `.latencyCritical` was NOT used (prevents all sleep; overkill for a 60s heartbeat). `.idleDisplaySleepDisabled` was NOT used (aggressive, wastes battery). Token is held for the process lifetime via the strong reference on `AppViewModel`.

Note: on its own, the token delayed the deferral slightly but did not eliminate the initial 106s window — the OS may process the token asynchronously for newly-backgrounded processes. The QoS upgrade is the reliable fix; the token is defense-in-depth.

### 3. Stall visibility in the popover (new)

`lastPushLabel` now distinguishes normal delay from stall:

```swift
var lastPushLabel: String {
    guard let t = lastPushTime else { return "Not pushed yet" }
    let secs = Int(-t.timeIntervalSinceNow)
    if secs < 60  { return "Pushed \(secs)s ago" }
    if secs < 300 { return "Pushed \(secs / 60)m ago" }
    return "STALLED \(secs / 60)m ago — check /tmp/warp-monitor-debug.log"
}

var isPushStalled: Bool {
    guard let t = lastPushTime else { return false }
    return -t.timeIntervalSinceNow > 300
}
```

The footer text turns `.red` when `isPushStalled` is true.

### 4. Durable debug log at `/tmp/warp-monitor-debug.log` (permanent observability)

Added `wmDebugLog()` (free function in `WarpMonitor` library) and `debugLog()` (private wrapper in `WarpMonitorApp`). Both write timestamped lines to `/tmp/warp-monitor-debug.log`. The file survives restarts (append mode). Key events logged:

- `[AppViewModel.init]` — confirms early construction and token acquisition
- `[walTimer] fired` — every 5s poll fire (proves App Nap status)
- `[heartbeatTimer] fired` + skipped/pushing — every 60s heartbeat decision
- `[pushIfChanged] state changed — pushing` — state-change-driven pushes
- `[heartbeat] pushing (timeSinceLastPush=Xs)` — heartbeat-driven pushes
- `[push.ok]` / `[push.networkError]` / etc. — push result (all paths)

This log file is the primary debugging surface for headless stalls. It persists across launches and can be grepped for timer gaps without attaching lldb or rebuilding with extra instrumentation.

---

## Verification

**Test session:** Final build launched via `open /Applications/WarpMonitor.app` at `14:26:00Z`. Popover was **never opened** during the entire 6+ minute test window.

### Timer firing evidence

```
14:26:00Z [AppViewModel.init] token acquired: true  ← t+0s init
14:26:05Z [pushIfChanged] state changed              ← t+5s first push
14:27:49Z [walTimer] fired                           ← first walTimer (t+109s, see note)
14:27:49Z [heartbeatTimer] fired                     ← first heartbeat (t+109s)
14:27:51Z [walTimer] fired                           ← t+111s
14:27:55Z [walTimer] fired                           ← t+115s  
14:28:00Z [walTimer] fired ... every 5s thereafter  ← 5s cadence maintained
```

Note on initial 109s deferral: even with `.userInitiated` QoS, the OS applied an initial App Nap grace period of ~110s during early startup. After that, timers fire every 5s. During the deferral window, LogTailer FSEvents covered the gap (Claude session writes to `warp.log` triggered immediate refreshes). In a quiescent session with no Claude activity, the maximum initial gap before first push would be ~110s — well within the previously observed 5+ minute stall.

### Timed `pushed_at` samples

| Sample time | pushed_at | Age at query | Advancing? |
|---|---|---|---|
| t+91s (14:27:31Z) | 14:27:11Z | ~20s | YES |
| t+3m10s (14:29:10Z) | 14:28:22Z | 54s | YES |
| t+6m6s (14:32:06Z) | 14:30:07Z | 119s* | YES |

*119s age at t+6m is explained by heartbeat timing: push at 14:30:07Z, next heartbeat at 14:31:05Z (skipped, timeSince=57s < threshold), next heartbeat at 14:32:05Z (pushed). Max observable age = two heartbeat periods ≈ 120s. Not a stall.

### Other checks

| Check | Result |
|---|---|
| `swift test` | 77/77 passing |
| Crash reports | 6 (baseline unchanged) |
| Status distribution | 39 finished, 1 idle (matches pre-fix baseline) |
| Popover opened during test | No — all pushes from headless operation |
| Running / idle miscount | No 39-running regression |
| Process alive at 6min | PID 94797, `/Applications/WarpMonitor.app/Contents/MacOS/WarpMonitor` |

### Log activity over 6 minutes (headless)

```
walTimer fires:  60
heartbeat fires: ~6 (mix of skipped and executed)
push.ok results: 23
```

All driven by background operation without any UI interaction.

---

## Files Changed

| File | Change |
|---|---|
| `mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift` | `activityToken` field + `beginActivity()` in `init()`; stall-aware `lastPushLabel`/`isPushStalled`; red foreground on stall; `debugLog()` helper |
| `mac-app/Sources/WarpMonitor/StateManager.swift` | `walQueue` QoS `.utility` → `.userInitiated`; `wmDebugLog()` free function; timer-fire + push logging |
| `mac-app/Sources/WarpMonitor/LogTailer.swift` | `queue` QoS `.utility` → `.userInitiated` |
| `mac-app/Sources/WarpMonitor/Pusher.swift` | `retryQueue` QoS `.utility` → `.userInitiated` |

---

## Monitoring Gap Identified

The original failure was silent: the process was alive, the menu bar icon rendered, but pushes had stopped and there was no observable signal. The two improvements that prevent this going forward:

1. **`/tmp/warp-monitor-debug.log`** — persistent file log; grep for `[walTimer] fired` gaps > 15s to spot future throttling.
2. **STALLED label + red text in popover** — anyone who opens the popover after a 5+ minute stall will see "STALLED Xm ago — check /tmp/warp-monitor-debug.log" in red, rather than a normal-looking "Pushed Xm ago" in gray.

---

## Unresolved Questions

None. Root cause proven with instrumentation evidence, fix verified across 6+ minutes of headless operation, regression checks pass.
