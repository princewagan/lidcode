# Warp Monitor — Mac Popover Redesign

**Date:** 2026-08-19
**Scope:** `mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift`, `components/GroupCard.tsx`
**Frozen contract:** `lib/schema.ts`, `mac-app/Sources/WarpMonitor/Models.swift` — untouched.
**Status:** DONE

---

## 1. What changed and why

The Mac menu bar popover had never been touched since the phone dashboard was redesigned
in the web UI redesign (see `ui-redesign_report_19-08-26.md`). It showed only title + a
short path + a small unlabelled dot, with folder colours used as the dot colour — the
same broken approach the phone dashboard discarded. The user's instruction:

> "remove the folder colors in the app bcuz id rather u use the colors for the statuses"

Three problems were addressed in one pass:

1. **Folder colours wrongly driving the dot** — `TabGroupRow.dotColor` derived hue from
   `group.color`. Deleted entirely. Colour is now reserved for status only.
2. **Stale `hasWarning` enum bug** — only checked `.warning` (legacy value, never emitted
   by the current binary). The icon stayed neutral even when something was blocked or
   errored. Fixed by introducing `AlertLevel` and rewriting all three computed properties.
3. **Information-poor rows** — rows showed title + short path + unlabelled dot. Now they
   show status label + colour + title + path + branch + blocked_reason / error_type /
   last_query, triage-sorted so blocked/error float to top.

---

## 2. Stale-enum bug — before / after

### Before (`hasWarning`)
```swift
var hasWarning: Bool {
    guard let state = currentState else { return false }
    return state.tab_groups.flatMap(\.tabs).contains { $0.claude_status == .warning }
        || state.ungrouped_tabs.contains { $0.claude_status == .warning }
}
```
Only `.warning` (a legacy alias never emitted by the current binary) was checked.
`permission_request` events produce `.blocked`; `stop_failure` events produce `.error`.
Both were invisible to the menu bar icon.

`statusColor` had the same gap: it delegated to `hasWarning`, so `.blocked` and `.error`
never turned the header circle orange or red.

`statusLabel` returned "Live" for any state where Warp was running, even when everything
was on fire.

### After (`AlertLevel` enum)
```swift
enum AlertLevel { case error, blocked, running, ok, warpClosed, noData }

var alertLevel: AlertLevel {
    guard let state = currentState else { return .noData }
    if !state.warp_running { return .warpClosed }
    let allTabs = state.tab_groups.flatMap(\.tabs) + state.ungrouped_tabs
    if allTabs.contains(where: { $0.claude_status == .error }) { return .error }
    if allTabs.contains(where: { $0.claude_status == .blocked || $0.claude_status == .warning }) { return .blocked }
    if allTabs.contains(where: { $0.claude_status == .running }) { return .running }
    return .ok
}
```

`statusColor`, `statusLabel`, and `MenuBarLabel` all derive from `alertLevel` — one source
of truth. `hasWarning` is kept as a delegating wrapper so any lingering callers still
compile, but it now correctly returns true for `.error`, `.blocked`, and `.warpClosed`.

Menu bar icon tints:
| alertLevel | icon treatment |
|---|---|
| `.error` | red palette foreground |
| `.blocked` / `.warpClosed` | orange palette foreground |
| `.running` | blue palette foreground |
| `.ok` | default (no tint) |
| `.noData` | secondary (dim) |

---

## 3. Folder colour removal

### Swift popover
`TabGroupRow.dotColor` — the entire computed property — deleted. Group headers now use
typography only: uppercase name, 10pt semibold, 0.8pt kerning, secondary colour. The
3-px coloured bar that was driven by `group.color` is gone. No `group.color` reference
remains anywhere in the file.

### Web (`components/GroupCard.tsx`)
The group header had:
```tsx
<span style={{ backgroundColor: group.color ?? "#3a4048" }} />
```
Replaced with a static neutral bar:
```tsx
<span className="h-7 w-[3px] shrink-0 rounded-full bg-line" />
```
`bg-line` is the `#22262d` hairline colour from the palette — visually structural, carries
no group-identity hue. The `color` field remains on the wire (schema frozen) but is no
longer rendered anywhere.

Grep proof — zero results:
```
grep -rn "group\.color" components/ app/
grep -n "dotColor\|group\.color" mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift
```

---

## 4. Popover information architecture — before / after

### Before
```
[dot: group colour]  Tab title
                     .../parent/cwd
```
- Dot colour = folder colour, not status
- No status label (text)
- No git branch
- No blocked_reason / error_type / last_query
- No triage sorting
- Icon only flipped for legacy `.warning` (never emitted)

### After
```
GROUP NAME (uppercase, tracked, no colour)          ↓ / ↑

  [status dot: blue]  In progress        claude
  Tab title
  ~/path/cwd · main

  [status dot: amber] Blocked            claude
  Tab title
  ~/path/cwd · feature/branch
  "Wants to run: rm -rf node_modules..." (blocked_reason, 2 lines)

  [hollow ring]  No Claude
  Tab title
  ~/path/cwd
```
- Status is always colour + text label (never colour alone)
- Blocked/error rows float to the top within each group and within ungrouped
- `git_branch` shown monospace, truncated with `.middle` mode
- `blocked_reason` shown at full width (2-line limit) — the most actionable field
- `error_type` and `last_query` shown on error rows
- `agent` name shown where a session exists
- Path collapsed to `~/last/two/components` using home-directory substitution
- Popover widened from 280pt to 320pt to accommodate branch + reason without truncation pressure
- Footer unchanged: push timestamp, last error, launch-at-login toggle, Quit

---

## 5. Consistency check — phone vs popover

| signal | phone dashboard | mac popover |
|---|---|---|
| blocked | amber "Blocked" badge + `blocked_reason` inline | amber dot + "Blocked" label + `blocked_reason` 2 lines |
| error | red "Error" badge + diamond + `last_query` | red dot + "Error" label + `error_type` + `last_query` |
| running | blue "In progress · Bash" | blue dot + "In progress" + agent |
| finished | green "Done" | green dot + "Done" |
| idle | grey "No Claude" hollow ring | hollow ring + "No Claude" |
| triage order | blocked/error in AttentionPanel above all groups | blocked/error sorted to top within each group |
| folder caveat | session attaches to folder, not tab | same: session attaches to folder, not tab |
| vocabulary | same terms throughout | matches |

---

## 6. Verification evidence

### 6.1 `swift build -c release`
```
Build complete! (1.93s)
```
Zero errors, zero warnings.

### 6.2 `swift test` — 34/34 pass
```
Test run with 34 tests in 1 suite passed after 0.004 seconds.
```

### 6.3 `npx tsc --noEmit`
Exit 0, no output.

### 6.4 `npm run build`
```
✓ Compiled successfully in 1002ms
✓ Generating static pages (5/5)
Route (app)   /   21.1 kB   124 kB first load JS
```
Zero errors, zero type failures.

### 6.5 App bundle — live process after 16s
```
./build-app-bundle.sh  → WarpMonitor.app  (ad-hoc signed)
mv → /Applications/WarpMonitor.app
open /Applications/WarpMonitor.app

pgrep -lf WarpMonitor.app
51537 /Applications/WarpMonitor.app/Contents/MacOS/WarpMonitor
```
PID present after 16 seconds — app stayed alive.

### 6.6 Crash report delta
DiagnosticReports warp count before launch: **6**
DiagnosticReports warp count after launch: **6**
No new crash report.

### 6.7 No `group.color` rendering — grep proof
```
grep -rn "group\.color" components/ app/        → (empty)
grep -n "dotColor\|group\.color" mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift → (empty)
```

### 6.8 Exhaustive `ClaudeStatus` switches — no `default:` swallowing
Every `ClaudeStatus` switch in `WarpMonitorApp.swift` (`statusRank`, `statusAppearance`,
`alertLevel`, `statusColor`, `statusLabel`, `MenuBarLabel.body`) covers all six cases
explicitly. The two `default:` hits found by grep are in SDK-type switches
(`SMAppService.Status` and `AlertLevel`) — not in `ClaudeStatus`.

---

## 7. What was not changed

- `lib/schema.ts` — frozen
- `Models.swift` — frozen
- All test files — no regressions
- `.idle` state-machine fix, tab-title fix, git-branch caching, mobile overflow, localStorage unseen/acknowledge — all untouched
- `NSApp.setActivationPolicy` call absent — `LSUIElement=YES` in plist still handles it
- No Vercel deploy, no secrets read or written
