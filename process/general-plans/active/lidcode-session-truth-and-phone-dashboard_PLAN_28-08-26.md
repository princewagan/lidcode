# LidCode Session Truth and Phone Dashboard
**PLAN** | COMPLEX | 28-08-26
**Repos:** `/Users/princewagan/lidcode` (A), `/Users/princewagan/television` (B)
**Reference (read-only):** `/Users/princewagan/television/mac-app` (C)

---

## Overview

Fix six verified power-correctness bugs in LidCode, replace the false-session-detection
logic with a direct port of WarpMonitor's proven state machine, surface real session state
and foreign sleep blockers in the menu bar UI, push LidCode's own state to the television
Supabase backend (without clobbering what WarpMonitor already pushes), and build a
mobile-first `/lidcode` dashboard on the television Next.js site.

---

## Goals

1. The Mac never stays awake longer than the user's deadline — regardless of what processes
   are running in `ps`.
2. `pmset disablesleep 1` is applied ONLY while the lid is physically closed.
3. Only sessions with `status == .running` (not `.blocked`, `.finished`, `.error`) satisfy
   the keep-awake predicate.
4. The menu bar shows the Claude 5-hour utilization percentage as live text.
5. The phone at `television-pearl.vercel.app/lidcode` shows full Mac + session state and
   auto-refreshes.

---

## Frozen Contract (read this section first — all workstreams code against it)

### New Swift types introduced by this plan

These declarations are exhaustive and literal. No workstream may invent a different
signature for these types. If a change is needed, update this section and re-notify
all workstreams before coding.

```swift
// ── File: Sources/LidCodeKit/Power/ClamshellStateReader.swift (W1 owns) ──────

public enum PhysicalLidState: String, Codable, Sendable {
    case open
    case closed
    case unknown
}

public struct ClamshellReading: Codable, Sendable, Equatable {
    public var state: PhysicalLidState
    public var readAt: Date
    public var isStale: Bool          // true when readAt is older than 30s
}

public final class ClamshellStateReader: @unchecked Sendable {
    public static let shared = ClamshellStateReader()
    public func read() -> ClamshellReading   // cached ~5s, runs ShellCommand ioreg
}

// ── File: Sources/LidCodeKit/Session/AgentSession.swift (W2 owns, REPLACES AgentSessionReader.swift types) ──

public enum AgentStatus: String, Codable, Sendable {
    case running      // actively executing (only this satisfies the keep-awake predicate)
    case blocked      // waiting on user (permission_request) — does NOT keep Mac awake
    case error        // stop_failure — does NOT keep Mac awake
    case finished     // stop / idle_prompt / timed out — does NOT keep Mac awake
}

public struct AgentSessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String               // session UUID (also the transcript filename)
    public var agent: String            // "claude", "codex", or whatever OSC 777 emits
    public var cwd: String
    public var project: String
    public var title: String            // ai-title > pane_leaves.custom_vertical_tabs_title > cwd basename
    public var titleSource: String      // "ai-title" | "warp-pane-title" | "cwd-basename"
    public var status: AgentStatus
    public var lastEvent: String        // raw event string
    public var lastSeenAt: Date         // timestamp of the most recent OSC 777 event
    public var statusChangedAt: Date    // timestamp when status field last changed
}

public struct AgentSessionSnapshot: Codable, Sendable, Equatable {
    public var sessions: [AgentSessionInfo]   // ALL non-pruned sessions, all statuses
    public var activeCount: Int               // sessions where status == .running
    public var fallbackName: String?          // cwd basename when nothing is running
    public static let empty: AgentSessionSnapshot
}

// ── Fields added to RuntimeSnapshot (Model/AwakeState.swift, shared file — see change rules below) ──

// ADD to RuntimeSnapshot (after existing fields):
//   public var physicalLid: ClamshellReading
//   public var foreignBlockerCount: Int
//   public var agentSession: AgentSessionSnapshot   // replaces `session: SessionSnapshot`
// REMOVE from RuntimeSnapshot:
//   public var session: SessionSnapshot             // replaced by agentSession

// ── File: Sources/LidCodeKit/Push/LidCodePusher.swift (W4 owns) ──────────────

public struct LidCodePushPayload: Codable, Sendable {
    public var schema_version: Int                  // 1
    public var pushed_at: String                    // ISO8601
    public var mac_hostname: String
    public var awake_held: Bool
    public var physical_lid: String                 // "open" | "closed" | "unknown"
    public var hold_expires_at: String?             // ISO8601 or nil
    public var hold_elapsed_fraction: Double?       // 0...1, nil when no timed hold
    public var battery_percent: Int?
    public var battery_on_main: Bool
    public var temperature_celsius: Double?
    public var temperature_stale: Bool
    public var claude_five_hour_utilization: Double?
    public var claude_seven_day_utilization: Double?
    public var foreign_blocker_count: Int
    public var sessions: [LidCodeSessionPayload]
}

public struct LidCodeSessionPayload: Codable, Sendable {
    public var id: String
    public var agent: String
    public var project: String
    public var title: String
    public var status: String                       // AgentStatus.rawValue
    public var status_changed_at: String            // ISO8601
    public var last_seen_at: String                 // ISO8601
    public var cwd: String
}

public final class LidCodePusher: @unchecked Sendable {
    public init(configPath: String = "~/.warp-monitor.env")
    public func pushIfChanged(_ snapshot: RuntimeSnapshot)  // diff-only + 60s heartbeat
    // Non-blocking. Errors are logged only, never thrown.
}
```

### Shared-file change rules

`Model/AwakeState.swift` and `Model/Setting.swift` are edited by W1 only.
`Runtime/LidCodeRuntime.swift` is edited by W1 only.
`LidCodeApp/AppModel.swift` and `LidCodeApp/LidCodeApp.swift` are edited by W3 only
(W4's push client is instantiated and driven from AppModel).
Session-layer types under `Session/` are edited by W2 only, but W1 reads
`AgentSessionSnapshot.activeCount` from the snapshot to evaluate the hold predicate.

---

## File Ownership Table

| File path | Workstream | Action |
|---|---|---|
| `Sources/LidCodeKit/Power/ClamshellStateReader.swift` | W1 | CREATE |
| `Sources/LidCodeKit/Power/PowerAssertion.swift` | W1 | no change |
| `Sources/LidCodeKit/Power/TemperatureSensor.swift` | W1 | ADD staleness flag only |
| `Sources/LidCodeKit/Safety/SafetyGovernor.swift` | W1 | no change (predicate change is in Runtime) |
| `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift` | W1 | MODIFY heavily |
| `Sources/LidCodeKit/Model/AwakeState.swift` | W1 | MODIFY (new fields, remove old `session`) |
| `Sources/LidCodeKit/Model/Setting.swift` | W1 | MODIFY (narrow watchPattern default) |
| `Sources/LidCodeHelper/main.swift` | W1 | MODIFY (`disablesleep` conditional on lid) |
| `Sources/LidCodeKit/Session/AgentSessionReader.swift` | W2 | REWRITE (keep file, replace contents) |
| `Sources/LidCodeKit/Session/AgentSession.swift` | W2 | CREATE (new model types) |
| `Sources/LidCodeKit/Session/TranscriptMtimeReader.swift` | W2 | CREATE |
| `Sources/LidCodeKit/Session/AITitleReader.swift` | W2 | CREATE (ported from WarpMonitor) |
| `Sources/LidCodeKit/Session/ClaudeUsageReader.swift` | W2 | no change |
| `Sources/LidCodeApp/LidCodeApp.swift` | W3 | no change |
| `Sources/LidCodeApp/AppModel.swift` | W3 | MODIFY (push client, UI fields) |
| `Sources/LidCodeApp/MenuView.swift` | W3 | MODIFY (session section, blocker line, header) |
| `Sources/LidCodeApp/View/Gauge.swift` | W3 | no change |
| `Sources/LidCodeKit/Push/LidCodePusher.swift` | W4 | CREATE |
| `television/app/api/lidcode/route.ts` | W5 | CREATE |
| `television/app/lidcode/page.tsx` | W5 | CREATE |
| `television/lib/lidcodeSchema.ts` | W5 | CREATE |
| `television/lib/lidcodeStorage.ts` | W5 | CREATE |
| `television/db/schema.sql` | W5 | APPEND (new table) |
| Tests targeting W1 changes | W1 | CREATE/MODIFY |
| Tests targeting W2 changes | W2 | CREATE/MODIFY |

---

## Part 1 — LidCode Power Correctness (W1)

### 1.1 — Create `ClamshellStateReader`

**File:** `Sources/LidCodeKit/Power/ClamshellStateReader.swift`

- Implement the types defined in the Frozen Contract above.
- `read()` runs `ShellCommand.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"], timeoutSecond: 3)`.
  - Scan output for `"AppleClamshellState" = Yes` → `.closed`; `= No` → `.open`; timeout or no match → `.unknown`.
- Cache the result for 5 seconds (compare `readAt + 5 < Date()`). The cache is protected by `NSLock`.
- `isStale` is set when `Date().timeIntervalSince(readAt) > 30`.
- **Done signal:** `ClamshellStateReader.shared.read().state` prints `.closed` when the test machine's lid is closed (validated manually in step 6.3).

### 1.2 — Narrow `ProcessWatcher` default watchPattern

**File:** `Sources/LidCodeKit/Model/Setting.swift`, `watchPattern` default array.

Replace the existing 24-item default with ONLY these six entries:
`["claude", "codex", "cursor-agent", "aider", "xcodebuild", "swift-frontend"]`

Remove: `cargo`, `rustc`, `make`, `ninja`, `gradle`, `npm`, `pnpm`, `yarn`, `tsc`, `esbuild`,
`python`, `pytest`, `uv`, `poetry`, `docker`, `ffmpeg`, `rsync`, `pandoc`.

Rationale from spec: process presence alone must never satisfy the keep-awake predicate
(that is now handled by the session truth system in Part 2). The remaining six entries are
agent-shaped binaries that do real AI work and have no idle daemon form.

**Done signal:** `swift test --filter ProcessWatcherTests` passes; existing tests that
hardcode the default pattern list are updated to match the new six-item list.

### 1.3 — Rewrite the keep-awake predicate in `LidCodeRuntime`

**File:** `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`

The predicate evaluated inside `tick()` before calling `beginHoldLocked` or `stopLocked`:

```
let hasActiveSession = session.activeCount > 0          // W2 delivers this
let lidClosed = physicalLid.state == .closed
let safetyOk = safetyLock == nil
let userOk = !isUserPaused
let deadlineOk = expiresAt == nil || Date() < expiresAt

let shouldHold = isEnabled
               && (hasActiveSession || !activeLease.isEmpty)   // session truth OR explicit claim
               && safetyOk && userOk && deadlineOk
```

- When `shouldHold == false` AND `isHeld`:
  - Call `assertion.release()`.
  - When lid is open: release only (do not force sleep).
  - When lid is closed AND stop reason is `.timerExpired`: call `helper.sleepNow(reason:)`.
- When `shouldHold == true` AND `!isHeld` AND `safetyLock == nil`: call `beginHoldLocked`.
- `ProcessWatcher` results still feed into `registry.replaceProcessLease()`, but process
  leases alone do NOT satisfy `shouldHold` — the `hasActiveSession` signal is required
  when mode is `.smart` and `activeLease` are all process-sourced.

  Concretely: add a `func isProcessOnlyLease() -> Bool` to `LeaseRegistry` that returns
  `true` when all active leases are `.process` source. In the predicate, substitute:
  ```
  let hasRealWork = hasActiveSession || activeLease.contains { $0.source != .process }
  ```

**Done signal:** Integration test `HoldPredicateTests.testProcessAloneDoesNotHold` passes.

### 1.4 — Fix `beginHoldLocked` deadline ordering bug (BUG 2)

**File:** `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`, `beginHoldLocked`.

Move the `expiresAt` assignment to AFTER the `guard !isHeld` line so a new nil-second
call cannot silently overwrite a live deadline on an already-held session.

```swift
// Current (wrong):
expiresAt = ...
guard !isHeld else { publish(); return }

// Fixed:
guard !isHeld else {
    // Only update expiry when explicitly supplied, never clear it.
    if let second { expiresAt = Date().addingTimeInterval(...) }
    publish()
    return
}
expiresAt = second.map { Date().addingTimeInterval(...) } ?? expiresAt
```

**Done signal:** `RuntimeCacheTests.testDeadlineNotClearedOnReacquire` (new test) passes.

### 1.5 — Fix `beginHoldLocked` nil-second call paths (BUG 1)

**File:** `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`.

Every internal call to `beginHoldLocked(second: nil, ...)` must be changed to
`beginHoldLocked(second: setting.holdSecond, ...)` so every auto-started hold respects
the user's configured deadline.

Callers to audit and fix:
- `applyScan(_:)` line ~899
- `claim(...)` internal call (line ~540)
- `setGuard(...)` internal recovery call (line ~414)

Additionally: after a `.timerExpired` stop, set a `cooldownUntil: Date?` field
(initially nil). During `applyScan`, `claim`, and any auto-rearm path: if
`Date() < cooldownUntil` skip `beginHoldLocked`. The cooldown expires when:
- The user explicitly toggles the switch back on (clears `cooldownUntil`).
- All sessions go to `.finished` and a new one starts (clears `cooldownUntil` on
  first `session_start` event observed via the session reader returning
  `activeCount > 0` where it was previously 0).

**Done signal:** Integration test `HoldPredicateTests.testTimerExpiredCooldown` passes.
Manual: set a 30s hold, let it expire, confirm Mac does not re-arm within the next 60s.

### 1.6 — `disablesleep` conditioned on physical lid (BUG 3)

**File:** `Sources/LidCodeHelper/main.swift` and `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`.

The helper's `ClamshellGuard.set(_:)` already gates on the request value. The change is
in the runtime: before calling `helper.setClamshell(isOn: true)`, check
`ClamshellStateReader.shared.read().state == .closed`. If the lid is open, skip the
`disablesleep 1` call but still hold the IOPMAssertion.

In `tick()`, add a lid-state check: if `isClamshellActive && physicalLid.state == .open`,
call `helper.setClamshell(isOn: false)` asynchronously (non-blocking, helper.disconnect
fallback). This corrects a stuck `disablesleep 1` when the user opens the lid without
going through the UI toggle.

**Done signal:** `pmset -g | grep SleepDisabled` returns `SleepDisabled = 0` within one
tick period (5s) after opening the lid while LidCode is active.

### 1.7 — Deadline expiry: sleep on lid-closed (step 1.5 in spec, requirement 1.5)

**File:** `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`, `tick()` timer-expiry branch.

```swift
if let expiresAt, Date() >= expiresAt {
    let lidClosed = ClamshellStateReader.shared.read().state == .closed
    stopLocked(reason: .timerExpired)
    if lidClosed {
        try? helper.sleepNow(reason: "Session timer expired with lid closed")
        log.append(LogEntry(kind: .note, detail: "pmset sleepnow after timer expiry (lid was closed)"))
    }
    return
}
```

**Done signal:** With lid closed and a 60s test hold, the Mac sleeps within 5s of the
deadline. With lid open and a 60s test hold, the Mac does NOT force-sleep (normal OS sleep
behaviour applies).

### 1.8 — Persist `expiresAt` across app restart

**File:** `Sources/LidCodeKit/Model/Setting.swift` (add field) and
`Sources/LidCodeKit/Runtime/LidCodeRuntime.swift` (persist and restore).

Add `var activeHoldExpiresAt: Date?` to `Setting`. On `beginHoldLocked`, write
`setting.activeHoldExpiresAt = expiresAt` and call `persistLocked()`. On `start()`,
read `setting.activeHoldExpiresAt` and if it is in the future, call
`beginHoldLocked(second: nil, mode: .smart)` with the restored expiry.

**Done signal:** Kill and reopen LidCode mid-hold; `lidcode status` shows the original
expiry, not a fresh 8-hour window.

### 1.9 — Temperature staleness flag

**File:** `Sources/LidCodeKit/Power/TemperatureSensor.swift` — no change to `TemperatureSensor`.
**File:** `Sources/LidCodeKit/Model/AwakeState.swift` — `ThermalReading` already has `.celsius`.

Add a `isCelsiusStale: Bool` to `ThermalReading` (or annotate `RuntimeSnapshot.thermal`
with a derived property). The staleness condition: `ThermalReader.read()` returns a
`ThermalReading` with `celsius != nil`; stale = the previous cached read was > 30s ago.

Concretely: in `LidCodeRuntime.tick()`, capture `let thermalAt = Date()` and store it in a
`lastThermalAt: Date?` ivar. In `makeSnapshot()`, add
`thermal.isCelsiusStale = lastThermalAt.map { Date().timeIntervalSince($0) > 30 } ?? false`.

Validation: run `sudo powermetrics -n 1 -i 1000 --samplers cpu_power` and confirm the
temperature visible in LidCode's menu is within ±3°C.

**Done signal:** `snapshot.thermal.celsius` is non-nil and matches `powermetrics` output
within 3°C. `isCelsiusStale` becomes `true` if the tick stalls (observable via log).

### 1.10 — Add `physicalLid` and `foreignBlockerCount` to `RuntimeSnapshot`

**File:** `Sources/LidCodeKit/Model/AwakeState.swift`.

```swift
// Add to RuntimeSnapshot:
public var physicalLid: ClamshellReading
public var foreignBlockerCount: Int   // count of sleep assertions NOT from LidCode
```

The `physicalLid` is populated by calling `ClamshellStateReader.shared.read()` inside
`makeSnapshot()` (runs on queue, so no thread issue).

`foreignBlockerCount` is computed by `LidCodeRuntime.tick()` once per tick:
```swift
// Run ShellCommand: /usr/bin/pmset -g assertions
// Count lines matching "PreventUserIdleSystemSleep" that do NOT contain "LidCode"
```
Cache this count; it changes rarely. Add `var cachedForeignBlockerCount: Int = 0` to
the runtime and recompute it every 6 ticks (same cadence as health).

Add to `RuntimeSnapshot.init(from decoder:)` with safe defaults:
- `physicalLid = ClamshellReading(state: .unknown, readAt: Date(), isStale: true)`
- `foreignBlockerCount = 0`

**Done signal:** `snapshot.physicalLid.state` matches the observed lid state.
`snapshot.foreignBlockerCount` matches the count of non-LidCode entries in
`pmset -g assertions | grep PreventUserIdleSystemSleep`.

---

## Part 2 — Session Truth (W2)

### 2.1 — Create `AgentSession.swift` with new model types

**File:** `Sources/LidCodeKit/Session/AgentSession.swift`

Declare exactly the types in the Frozen Contract above:
`AgentStatus`, `AgentSessionInfo`, `AgentSessionSnapshot`.

`AgentSessionSnapshot.empty` returns `AgentSessionSnapshot(sessions: [], activeCount: 0, fallbackName: nil)`.

`AgentSessionSnapshot.activeCount` is a computed property:
`sessions.filter { $0.status == .running }.count`.

**Done signal:** File compiles with zero warnings.

### 2.2 — Create `AITitleReader.swift` (ported from WarpMonitor)

**File:** `Sources/LidCodeKit/Session/AITitleReader.swift`

Direct port of `/Users/princewagan/television/mac-app/Sources/WarpMonitor/AITitleReader.swift`
with these adaptations:
- Remove all `WarpTab`-specific code (the `resolve(cwd:sessionId:) -> TitleResult` method stays).
- Replace `public final class AITitleReader` with `final class AITitleReader: @unchecked Sendable` (internal, not public, since LidCodeKit does not re-export it separately).
- Keep `static func encodeProjectDir(cwd:)`, `static func transcriptPath(cwd:sessionId:)`,
  `func aiTitle(at:)`, `func transcriptMtime(at:)`, `func resolve(cwd:sessionId:) -> TitleResult`.
- The `TitleResult` struct stays identical.
- Cache by `(path, mtime, size)` exactly as in WarpMonitor.
- Read last 256 KB from end of transcript, scan backwards for `"type":"ai-title"`.

**Done signal:** Unit test `AITitleReaderTests.testReadsLastAITitle` passes with a
synthetic JSONL fixture containing multiple `ai-title` lines.

### 2.3 — Create `TranscriptMtimeReader.swift`

**File:** `Sources/LidCodeKit/Session/TranscriptMtimeReader.swift`

Thin wrapper: given a `(cwd: String, sessionId: String)` pair, return the `mtime: Date?`
of `~/.claude/projects/<encodedCwd>/<sessionId>.jsonl` using `FileManager.attributesOfItem`.
Internally delegates to `AITitleReader` (which already does this stat for its cache). This
type exists only to name the dependency explicitly rather than having the session reader
reach into `AITitleReader` directly.

```swift
final class TranscriptMtimeReader: @unchecked Sendable {
    private let ai: AITitleReader
    init(ai: AITitleReader = AITitleReader()) { self.ai = ai }
    func mtime(cwd: String, sessionId: String) -> Date? {
        let path = AITitleReader.transcriptPath(cwd: cwd, sessionId: sessionId)
        return ai.transcriptMtime(at: path)
    }
}
```

**Done signal:** File compiles; used by `AgentSessionReader.read()` in step 2.4.

### 2.4 — Rewrite `AgentSessionReader.swift`

**File:** `Sources/LidCodeKit/Session/AgentSessionReader.swift`

Replace the entire implementation. Keep the file name and `public final class AgentSessionReader`
declaration for zero-impact on `LidCodeRuntime.swift`'s initialiser.

Internal state machine type (private):
```swift
private struct InternalSession {
    var id: String
    var agent: String
    var cwd: String
    var project: String
    var lastEvent: String
    var lastEventAt: Date
    var status: AgentStatus           // derived from last event
    var statusChangedAt: Date         // when status last changed
    var lastSeenAt: Date
    var timedOut: Bool = false
}
```

State machine transitions (identical to WarpMonitor `ClaudeSessionState.apply`):
- `session_start | prompt_submit | tool_complete` → `.running`
- `idle_prompt | stop` → `.finished`
- `permission_request` → `.blocked`
- `stop_failure` → `.error`

Activity window / hysteresis (identical to WarpMonitor `activityStatus`):
- `activityWindow = 60s`, `activityGrace = 15s`
- If `status == .blocked || status == .error` → return that status as-is (sticky).
- If `isInFlight` (last event was `tool_complete` or `prompt_submit`) → `.running`.
- Else: check transcript mtime. If within `activityWindow` (+ grace if currently running) → `.running`. Else → `.finished`.
- `isInFlight` = `(status == .running) && (lastEvent == "tool_complete" || lastEvent == "prompt_submit")`.

Timeout and prune rules (identical to WarpMonitor):
- Running sessions silent > 600s → `.finished` (timedOut).
- Finished sessions older than 1800s → pruned.
- Blocked and error sessions are NEVER pruned (require user to resolve).

Title resolution: call `AITitleReader.resolve(cwd:sessionId:)`.
- Priority: `ai-title` from JSONL > `pane_leaves.custom_vertical_tabs_title` (Warp sqlite) > cwd basename.
- The existing `warpTabName(databaseURL:)` sqlite query is extended: also select
  `pane_leaves.custom_vertical_tabs_title` alongside `tabs.custom_title` (see 2.4a below).

Codex handling: Codex sessions emit the same OSC 777 events with `agent == "codex"`.
They are processed identically to Claude sessions. If no transcript JSONL exists under
`~/.claude/projects/` (which is likely for Codex), fall back to the log-event state machine
only, with a shorter idle window: `codexIdleWindow = 300s` instead of 600s.
Flag this as needing real-world verification in a `// CODEX_VERIFY` comment.

The new `read()` method returns `AgentSessionSnapshot` (not `SessionSnapshot`).
The old `SessionSnapshot` type is REMOVED from this file (it is no longer used).

**Done signal:**
- `swift test --filter AgentSessionReaderTests` passes.
- With a live Claude Code session, `snapshot.agentSession.sessions` shows at least one
  `AgentSessionInfo` with `status == .running` and a real ai-title.

### 2.4a — Extend Warp sqlite query for `custom_vertical_tabs_title`

**File:** `Sources/LidCodeKit/Session/AgentSessionReader.swift`

Update the static `tabQuery` string to also select `pane_leaves.custom_vertical_tabs_title`:
```sql
SELECT t.id,
       t.custom_title,
       tp.cwd,
       pl.is_focused,
       pl.custom_vertical_tabs_title
FROM tabs t
LEFT JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
LEFT JOIN terminal_panes tp ON tp.id = pl.pane_node_id
ORDER BY t.id;
```

Update `rowName(_:)` to prefer `custom_vertical_tabs_title` over `cwd` basename (it is
the agent's own wording, same priority as in WarpMonitor's `warpPaneTitleSource`).

**Done signal:** Unit test `AgentSessionReaderTests.testPaneTitle` passes with a mocked
sqlite that returns a row with `custom_vertical_tabs_title = "Fix sleep policy"`.

### 2.5 — Wire new snapshot type into `LidCodeRuntime`

**File:** `Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`

- Replace `private var session: SessionSnapshot = .empty` with
  `private var agentSession: AgentSessionSnapshot = .empty`.
- Replace `private let sessionReader: AgentSessionReader` (type stays the same class,
  but `read()` now returns `AgentSessionSnapshot`).
- In `tick()`: `agentSession = sessionReader.read()`.
- In `makeSnapshot()`: populate `agentSession` field; remove old `session` field.
- In `RuntimeSnapshot.init(from decoder:)`: decode `agentSession` with
  `decodeIfPresent`, default to `.empty`.

**Done signal:** `lidcode status` output still works (no nil-decode crash on the CLI side).

---

## Part 3 — LidCode UI (W3)

### 3.1 — Menu bar: add utilization percent text

**File:** `Sources/LidCodeApp/LidCodeApp.swift`, `AppDelegate.installStatusItem()`.

The `iconSink` currently maps `model.$snapshot` through `Icon.init` (which is `Equatable`)
and uses `removeDuplicates()`. The percent lives in `snapshot.usage?.fiveHour.utilization`.

Change the sink to map a combined `(Icon, String?)` tuple and use `removeDuplicates(by:)`
comparing both fields:

```swift
iconSink = model.$snapshot
    .map { s in (Icon(s), s.usage.map { "\(Int($0.fiveHour.utilization.rounded()))%" }) }
    .removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 })
    .sink { (icon, percent) in
        DispatchQueue.main.async { [weak self] in
            self?.applyIcon(icon, percent: percent)
        }
    }
```

Update `applyIcon(_:)` to `applyIcon(_ icon: Icon, percent: String?)`:
```swift
func applyIcon(_ icon: Icon, percent: String? = nil) {
    statusItem?.button?.image = NSImage(
        systemSymbolName: icon.symbolName,
        accessibilityDescription: icon.label
    )
    statusItem?.button?.title = percent ?? ""
    // imagePosition: show image on left when title is present, image-only otherwise
    statusItem?.button?.imagePosition = percent == nil ? .imageOnly : .imageLeft
}
```

When `usage == nil`, pass `percent: nil`; the button shows image only (no text, no extra width).

**Done signal:** Menu bar shows e.g. `⚡ 14%` when usage is available, bare icon when not.

### 3.2 — Update header string

**File:** `Sources/LidCodeApp/MenuView.swift`, `statusTitle` computed property.

Add two new cases before the existing `"Keeping awake"`:
```swift
private var statusTitle: String {
    if snapshot.isStalled { return "Not responding" }
    if snapshot.blockedBy != nil { return "Holding back" }
    if snapshot.isAwakeHeld || snapshot.isClamshellActive {
        let n = snapshot.agentSession.activeCount
        if n > 0 { return "Keeping awake · \(n) session\(n == 1 ? "" : "s")" }
        return "Keeping awake"
    }
    if snapshot.isAwakeHeld == false,
       snapshot.isClamshellActive == false,
       model.isEnabled {
        return "Waiting for a session"
    }
    return snapshot.isUserPaused ? "Paused by you" : "Idle"
}
```

The string must not exceed the 18pt height row at 340pt width. The longest expected value
`"Keeping awake · 10 sessions"` is 29 characters at 13pt semibold — this fits safely.
Use `.lineLimit(1)` (already set) and `.truncationMode(.tail)` as safety net.

**Done signal:** Header reads correctly across all states. `snapshot.agentSession.activeCount == 2`
produces `"Keeping awake · 2 sessions"`.

### 3.3 — Session list section

**File:** `Sources/LidCodeApp/MenuView.swift`, add `sessionSection` computed property.

Show only when `snapshot.agentSession.sessions` is non-empty.

Layout: rows stacked in a `VStack(spacing: 4)` inside the existing `VStack` above the
`Divider()`. Cap at 5 visible rows; if more, show a `"+N more"` text line.

Each row is a fixed 18pt height `HStack`:
- Left: 7pt circle filled with status colour:
  - `.running` → `Palette.brand`
  - `.blocked` → `Color.orange.opacity(0.8)`
  - `.error` → `Palette.brandDeep`
  - `.finished` → `Palette.brandSoft`
- Center: `Text(session.title).lineLimit(1).font(.system(size: 11))`.
- Right: relative time since `session.statusChangedAt` using `relativeTime(_:)` helper
  (e.g. "2m ago", "10m ago"). Font `.system(size: 10)`, `.foregroundStyle(.secondary)`.

`relativeTime(_:from:)` helper (add to `MenuView`):
```swift
private func relativeTime(_ date: Date, from now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}
```

All animations remain disabled (`.transaction { $0.animation = nil }`).

**Done signal:** With 3 live sessions of mixed status, the section renders 3 rows with
correct colours and "Xm ago" timestamps. With 7 sessions, 5 are shown plus "+2 more".

### 3.4 — Foreign blocker line

**File:** `Sources/LidCodeApp/MenuView.swift`.

Just below the session section (or header area), add a small info line when
`snapshot.foreignBlockerCount > 0`:

```swift
if snapshot.foreignBlockerCount > 0 {
    Text("\(snapshot.foreignBlockerCount) other app\(snapshot.foreignBlockerCount == 1 ? "" : "s") also blocking sleep")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 14, alignment: .leading)
        .help("Parsed from pmset -g assertions. Claude Code spawns caffeinate -i per session.")
}
```

Position: between `usageSection` and `Divider()`.

**Done signal:** With live Claude Code sessions (each spawns `caffeinate -i`), the line
reads e.g. "4 other apps also blocking sleep".

---

## Part 4 — Push Client (W4)

### 4.1 — Create `LidCodePusher.swift`

**File:** `Sources/LidCodeKit/Push/LidCodePusher.swift`

Implement the types defined in the Frozen Contract.

Config loading: identical to WarpMonitor's `Pusher.loadConfig()` — reads
`~/.warp-monitor.env`, parses `PUSH_SECRET` and `PUSH_URL` line by line. If the file is
missing or keys are absent, silently skip pushing (no throw, no crash).

Diff-only + heartbeat logic (identical to WarpMonitor):
```swift
public func pushIfChanged(_ snapshot: RuntimeSnapshot) {
    // Build LidCodePushPayload from snapshot
    // Hash payload (exclude pushed_at, same SHA256 approach as WarpMonitor)
    // If hash != lastHash → push immediately, update lastHash, lastPushAt
    // If Date() - lastPushAt >= 60s → heartbeat push regardless of hash
}
```

HTTP: `POST` to the `PUSH_URL` with `Authorization: Bearer <PUSH_SECRET>`,
`Content-Type: application/json`. `URLSession.shared` with `timeoutInterval = 15`.
On 4xx: log to stderr and do NOT retry (not retryable). On 5xx or network error:
retry up to 3 times with 2s, 4s, 8s backoff on a background `DispatchQueue`.

The push is dispatched asynchronously from the call site — it MUST NOT block the runtime
queue or the main thread.

Payload construction from `RuntimeSnapshot`:
- `physical_lid`: `snapshot.physicalLid.state.rawValue`
- `hold_expires_at`: `snapshot.expiresAt` formatted as ISO8601
- `hold_elapsed_fraction`: `snapshot.timerFraction`
- `battery_percent`: `snapshot.battery.percent`
- `battery_on_main`: `snapshot.battery.isOnMain`
- `temperature_celsius`: `snapshot.thermal.celsius`
- `temperature_stale`: `snapshot.thermal.isCelsiusStale`
- `claude_five_hour_utilization`: `snapshot.usage?.fiveHour.utilization`
- `claude_seven_day_utilization`: `snapshot.usage?.sevenDay.utilization`
- `foreign_blocker_count`: `snapshot.foreignBlockerCount`
- `sessions`: map `snapshot.agentSession.sessions` to `LidCodeSessionPayload`

**Done signal:** After enabling, `curl -s -H "Authorization: Bearer $PUSH_SECRET"
"$PUSH_URL_BASE/api/lidcode" | jq .sessions | length` returns the correct session count.

### 4.2 — Wire `LidCodePusher` into `AppModel`

**File:** `Sources/LidCodeApp/AppModel.swift`.

```swift
private let pusher = LidCodePusher()
```

In the `runtime.onChange` handler, after updating `self.snapshot`:
```swift
Task.detached { [weak self] in
    guard let self else { return }
    self.pusher.pushIfChanged(self.runtime.snapshot)
}
```

`Task.detached` ensures this runs off the main actor and does not add to the 5s tick budget.

**Done signal:** After a setting toggle, within 5s the Supabase `lidcode_state` row
`updated_at` changes.

---

## Part 5 — Website (W5)

### 5.1 — Add `lidcode_state` table to Supabase

**File:** `television/db/schema.sql` — append (do NOT modify existing DDL):

```sql
-- LidCode state — one row, id = 'current', pushed by LidCode.app on each state change.
-- Separate from warp_state so WarpMonitor and LidCode never clobber each other.
create table if not exists public.lidcode_state (
  id          text primary key,
  state       jsonb not null,
  updated_at  timestamptz not null default now()
);
alter table public.lidcode_state enable row level security;
-- Zero policies: only service-role key can access.
```

Run this in the Supabase SQL editor before deploying the API route.

**Done signal:** `select count(*) from lidcode_state` returns 0 (table exists, no rows yet).

### 5.2 — Create `lib/lidcodeSchema.ts`

**File:** `television/lib/lidcodeSchema.ts`

Zod schema mirroring `LidCodePushPayload` and `LidCodeSessionPayload` from the Frozen
Contract. All optional fields use `.optional()`. Schema version must be `z.literal(1)`.

```typescript
export const LidCodeSessionSchema = z.object({
  id: z.string(),
  agent: z.string(),
  project: z.string(),
  title: z.string(),
  status: z.enum(["running", "blocked", "error", "finished"]),
  status_changed_at: z.string().datetime(),
  last_seen_at: z.string().datetime(),
  cwd: z.string(),
});
export type LidCodeSession = z.infer<typeof LidCodeSessionSchema>;

export const LidCodeStateSchema = z.object({
  schema_version: z.literal(1),
  pushed_at: z.string().datetime(),
  mac_hostname: z.string(),
  awake_held: z.boolean(),
  physical_lid: z.enum(["open", "closed", "unknown"]),
  hold_expires_at: z.string().datetime().optional(),
  hold_elapsed_fraction: z.number().min(0).max(1).optional(),
  battery_percent: z.number().int().min(0).max(100).optional(),
  battery_on_main: z.boolean(),
  temperature_celsius: z.number().optional(),
  temperature_stale: z.boolean(),
  claude_five_hour_utilization: z.number().min(0).max(100).optional(),
  claude_seven_day_utilization: z.number().min(0).max(100).optional(),
  foreign_blocker_count: z.number().int().min(0),
  sessions: z.array(LidCodeSessionSchema),
});
export type LidCodeState = z.infer<typeof LidCodeStateSchema>;
```

**Done signal:** `npx tsc --noEmit` from the television repo exits 0.

### 5.3 — Create `lib/lidcodeStorage.ts`

**File:** `television/lib/lidcodeStorage.ts`

Identical shape to `lib/storage.ts` but targeting the `lidcode_state` table with
`ROW_ID = "current"`. Exports `upsertLidCodeState(blob)` and `readLidCodeState()`.
Reuses `getSupabaseClient()` — do NOT duplicate the Supabase client creation; import
a shared factory from `lib/storage.ts` or inline the same pattern with the same env vars.

**Done signal:** Unit test stubs compile; `upsertLidCodeState` returns `{ ok: true }`.

### 5.4 — Create `app/api/lidcode/route.ts`

**File:** `television/app/api/lidcode/route.ts`

Two handlers in the same file:

`POST` (Mac → Vercel write):
- Auth: `authorizeRequest(request)` (PUSH_SECRET only, same as `/api/push`).
- Parse body against `LidCodeStateSchema`.
- Upsert via `upsertLidCodeState(parsed)`.
- Return `{ ok: true }` or error JSON.

`GET` (phone → Vercel read):
- Auth: `authorizeReadRequest(request)` (VIEW_PASSWORD or PUSH_SECRET).
- Read via `readLidCodeState()`.
- Parse stored blob against `LidCodeStateSchema`.
- Return `{ ok: true, state: parsed }` or error.
- Header: `Cache-Control: no-store`.

`export const dynamic = "force-dynamic"` at the top of the file.

Do NOT import from `lib/schema.ts` — only from `lib/lidcodeSchema.ts`.
Do NOT call `upsertState` (the WarpMonitor function) from this file.

**Done signal:** `curl -X POST -H "Authorization: Bearer $PUSH_SECRET"
-H "Content-Type: application/json" -d '<minimal payload>' https://television-pearl.vercel.app/api/lidcode`
returns `{"ok":true}`.

### 5.5 — Create `app/lidcode/page.tsx`

**File:** `television/app/lidcode/page.tsx`

Mobile-first client component (`"use client"`). Auth pattern identical to `app/page.tsx`
(localStorage `wm_token`, TOKEN_KEY = `"lc_token"` to avoid collision, 401 clears and
re-prompts using the shared `TokenScreen` component).

Polling: `useQuery` with `queryFn: () => fetch("/api/lidcode", ...)`, `refetchInterval: 20_000`.

Layout (`max-w-lg mx-auto px-4 pb-6 pt-3`, dark only, `min-h-dvh bg-ink-0`):

**Header section:**
- Mac awake/asleep badge (green dot "Awake" / grey dot "Sleeping").
- Lid state badge ("Lid open" / "Lid closed").
- Hold timer: if `hold_expires_at` present, show `"Xh Ym left"` and a thin progress bar
  using `hold_elapsed_fraction`.
- Foreign blocker count: if > 0, small muted line `"N other apps blocking sleep"`.

**Battery + Temperature row:**
- Battery: percent bar + value, colour logic mirrors Palette (< hard → deep-red, < soft → orange, AC → muted).
- Temp: number + "°" label, colour mirrors Palette thermal levels.

**Claude usage bars:**
- `5-hour` and `1-week` bars. Same colour logic as `MenuView.usageSection`. Hidden when nil.

**Session list:**
- ALL sessions (not only running). Sort order: running first, then blocked, error, finished.
- Each row: status badge dot (same colours as step 3.3) + title + relative `"updated Xm ago"` from `status_changed_at`.
- Group or visually badge: status label in small caps to the left of each group change.
- No row cap — this is a scrollable page, not a fixed-height panel.

Thumb-sized tap targets (min-height 44px per row). No horizontal scroll. Auto-refresh
indicator (spinner when `isFetching && !isLoading`).

The existing `TokenScreen` component in `television/components/` is reused directly (same
token scheme).

**Done signal:** On a 390pt-wide viewport (Safari developer tools), all content is visible
without horizontal scroll. Session rows show correct status colours and relative times.

### 5.6 — Ensure WarpMonitor push path is unchanged

**Files touched:** NONE of the existing `app/api/push/route.ts`, `lib/storage.ts`,
`lib/schema.ts`, or `app/page.tsx`.

No modification to any existing television file outside the new files created in steps
5.1–5.5.

**Done signal:** `curl -X POST -H "Authorization: Bearer $PUSH_SECRET"
-H "Content-Type: application/json" -d '<valid WarpMonitorState>' https://television-pearl.vercel.app/api/push`
still returns `{"ok":true}` after the deployment.

---

## Part 6 — Ship

### 6.1 — Tests

```
cd /Users/princewagan/lidcode && swift test
```

Expected: 277 pass, 1 fail (`RuntimeCacheTest.testSetClamshellReportsFailureOnTheMainQueue`).
Do NOT attempt to fix the one known failure.

New tests to add (files in `Tests/LidCodeKitTests/`):
- `ClamshellStateReaderTests.swift` — mock `ShellCommand` output, verify `.closed`/`.open`/`.unknown`.
- `AgentSessionReaderTests.swift` — feed synthetic log lines, verify state machine transitions and timeout/prune rules.
- `AITitleReaderTests.swift` — synthetic JSONL fixtures.
- `HoldPredicateTests.swift` — verify cooldown, nil-second fix, process-only predicate.
- Update `ProcessWatcherTests.swift` — update default watchPattern expectation to new 6-item list.

### 6.2 — Build and deploy LidCode

```
cd /Users/princewagan/lidcode
bash Script/build-app.sh
cp -R dist/LidCode.app ~/Desktop/LidCode.app
# Relaunch the app
./.build/release/lidcode status
```

Verify output includes `physicalLid`, `agentSession.activeCount`, and `usage`.

### 6.3 — Real-world verification checklist (user performs)

1. Lid open, no Claude Code session → `pmset -g | grep SleepDisabled` shows `0`.
   No LidCode assertion visible in `pmset -g assertions`.
2. Start a Claude Code session → menu bar shows `"Keeping awake · 1 session"`.
   `pmset -g assertions | grep LidCode` shows one assertion.
3. Close the lid during an active session → within 5s:
   `pmset -g | grep SleepDisabled` shows `1`.
4. Open the lid again (session still running) → within 5s:
   `pmset -g | grep SleepDisabled` shows `0`.
5. Set a 5-minute hold, wait for expiry with lid closed → Mac sleeps within 5s of expiry.
6. Menu bar shows `⚡ 14%` (or whatever the current utilization is) when `warp-monitor-usage.json` exists.
7. `lidcode status` shows `physicalLid.state: open` or `closed` matching observed state.
8. Phone at `television-pearl.vercel.app/lidcode` shows sessions with real titles and correct statuses.

### 6.4 — Commits

LidCode repo (`/Users/princewagan/lidcode`):
- HEAD is f37d167. No remote yet. Commit now; push when user supplies GitHub remote.
- Logical commit split (use `vc-git-manager` if needed):
  1. `fix: narrow watchPattern to agent-only binaries (BUG 5)`
  2. `fix: apply disablesleep only when lid physically closed (BUG 3 + 4)`
  3. `fix: deadline always applied; cooldown after timer expiry (BUG 1 + 2)`
  4. `feat: port WarpMonitor session state machine into LidCodeKit`
  5. `feat: session list in MenuView; blocker count; utilization percent in icon`
  6. `feat: LidCode state push to television API`
  7. `test: add tests for hold predicate, session state machine, clamshell reader`

Television repo (`/Users/princewagan/television`):
- Has existing remote `github.com/princewagan/television`.
- Commit and push:
  1. `feat: add lidcode_state table and /api/lidcode route`
  2. `feat: /lidcode mobile dashboard page`

---

## Touchpoints

| From | To | Data |
|---|---|---|
| `ClamshellStateReader` | `LidCodeRuntime.tick()` | `ClamshellReading` |
| `AgentSessionReader.read()` | `LidCodeRuntime.tick()` | `AgentSessionSnapshot` |
| `LidCodeRuntime.makeSnapshot()` | `AppModel.snapshot` | `RuntimeSnapshot` |
| `AppModel.onChange` | `LidCodePusher.pushIfChanged()` | `RuntimeSnapshot` |
| `LidCodePusher` | `television /api/lidcode POST` | `LidCodePushPayload` JSON |
| `television /api/lidcode GET` | `app/lidcode/page.tsx` | `LidCodeState` JSON |
| `WarpMonitor Pusher` | `television /api/push POST` | `WarpMonitorState` JSON (unchanged) |

---

## Public Contracts

1. `AgentSessionSnapshot.activeCount: Int` — the single boolean the hold predicate reads.
   Must be 0 when all sessions are `.blocked`, `.finished`, or `.error`.
2. `RuntimeSnapshot.physicalLid: ClamshellReading` — required by W3 for UI and W4 for push.
3. `RuntimeSnapshot.foreignBlockerCount: Int` — required by W3 for UI and W4 for push.
4. `LidCodePushPayload` — the exact JSON shape the television API validates against `LidCodeStateSchema`.
5. `db/schema.sql` `lidcode_state` table — must exist before first push.

---

## Blast Radius / Risk Section

### HIGH RISK — stuck `disablesleep 1`

If step 1.6 is implemented incorrectly, `pmset -a disablesleep 1` could be left set on
lid open. The helper's deadman switch is the backstop (reverts within 15s of losing the
heartbeat connection), but it only fires on app quit/crash, not on logic errors in a live
app. Mitigation:
- Add an explicit tick-level check: `if isClamshellActive && physicalLid.state == .open → call helper.setClamshell(false)`.
- The helper's `ClamshellGuard.reconcileOnLaunch()` already reverts orphaned `disablesleep`
  on helper restart — unchanged, still present.
- Manual verification step 6.3 item 1 must be run before shipping.

### HIGH RISK — freeze history

The comment at the top of `LidCodeRuntime.swift` documents the freeze mechanism in detail:
any blocking I/O or `queue.sync` on the main thread can wedge the menu bar. The new
`LidCodePusher` must be invoked via `Task.detached` (step 4.2) — never synchronously
inside `onChange`. The `ClamshellStateReader.read()` call inside `makeSnapshot()` runs on
the runtime queue (not the main thread), but `ShellCommand.run` has a 3s timeout that would
delay the queue. Mitigation: `ClamshellStateReader` is cached at 5s; the `ShellCommand`
is invoked only on a cache miss. On cache hit, `read()` is a lock-guarded struct copy.

### MEDIUM RISK — `AgentSessionSnapshot` replacing `SessionSnapshot`

The old `session: SessionSnapshot` field is removed from `RuntimeSnapshot`. Any code that
accesses `snapshot.session` will fail to compile. W1 and W3 both read this field. The
Frozen Contract defines the new field name `agentSession`. The plan requires W1 and W3 to
update their access before merging. The `lidcode status` CLI decodes `RuntimeSnapshot` via
`Codable`; new field decoding must use `decodeIfPresent` with a safe default (step 2.5).

### MEDIUM RISK — television backward compatibility

The existing `/api/push` and `warp_state` table are NOT touched. However, the `lidcode_state`
table must be created in Supabase BEFORE the first LidCode push (step 5.1). If deployed out
of order, the first push returns a Supabase error that is logged and silently dropped
(per step 4.1's error handling policy). The Mac app does not crash; it retries on the next
60s heartbeat.

### LOW RISK — Codex session classification

Codex sessions are processed through the same OSC 777 log path. If Codex uses a different
log format or omits a field, the `guard body.agent == "codex"` condition catches it and the
session falls back to log-event state machine only. The `// CODEX_VERIFY` comment in step
2.4 marks this for real-world testing.

---

## Dependencies

- `ShellCommand` (already exists in LidCodeKit) — used by `ClamshellStateReader`.
- `SQLite3` (already linked via `LidCodeKit/Session/AgentSessionReader.swift`) — required by extended tab query.
- WarpMonitor's `AITitleReader` is ported directly (no Swift package dependency — the source is copied).
- `CryptoKit` (already linked in `StateManager.swift` in WarpMonitor; NOT needed in LidCodeKit since the pusher uses a simple SHA256 via `CryptoKit` or a string hash) — add `import CryptoKit` to `LidCodePusher.swift`.
- `television` NPM dependencies: no new packages required (`zod` already present, `@supabase/supabase-js` already present).

---

## Verification Evidence

- `swift test` output: 277/278. The one failure is `RuntimeCacheTest.testSetClamshellReportsFailureOnTheMainQueue`.
- `pmset -g | grep SleepDisabled` = 0 when lid open with no session. = 1 when lid closed with active session.
- Menu bar text "14%" (or live value) visible.
- `curl /api/lidcode GET` returns valid `LidCodeState` JSON.
- `/lidcode` phone page loads at 390pt without horizontal scroll.
- `swift test --filter AgentSessionReaderTests` passes (all new tests).
- `npx tsc --noEmit` in television exits 0.

---

## Resume and Execution Handoff

**Plan file:** `/Users/princewagan/lidcode/process/general-plans/active/lidcode-session-truth-and-phone-dashboard_PLAN_28-08-26.md`

**Workstream order for parallel execution:**
- W1 and W2 can run in parallel (no shared mutable files during implementation).
- W3 depends on W1 (needs `RuntimeSnapshot.physicalLid`, `foreignBlockerCount`) and W2
  (needs `agentSession` field). Start W3 after W1+W2 compile.
- W4 depends on W1 (needs complete `RuntimeSnapshot`) and W3 (wired from `AppModel`).
  Start W4 after W1 compiles.
- W5 is fully independent of W1–W4 on the Swift side. Run in parallel with all others.
  W5 step 5.1 (Supabase table) must complete before W4 can successfully push.

**Single execute path for a solo agent:**
1. W1 (power/lid/timer fixes) — compile and test.
2. W2 (session state machine) — compile and test.
3. W3 (UI) — compile.
4. W4 (push client) — compile.
5. Full `swift test` — expect 277/278.
6. W5 (television) — deploy and test.
7. `bash Script/build-app.sh` → deploy → verify checklist 6.3.

**Context files to pass to the execute agent:**
- This plan file.
- `/Users/princewagan/lidcode/Sources/LidCodeKit/Runtime/LidCodeRuntime.swift`
- `/Users/princewagan/lidcode/Sources/LidCodeKit/Model/AwakeState.swift`
- `/Users/princewagan/lidcode/Sources/LidCodeKit/Session/AgentSessionReader.swift`
- `/Users/princewagan/television/mac-app/Sources/WarpMonitor/StateManager.swift`
- `/Users/princewagan/television/mac-app/Sources/WarpMonitor/AITitleReader.swift`
- `/Users/princewagan/television/lib/schema.ts`
- `/Users/princewagan/television/app/api/push/route.ts`
