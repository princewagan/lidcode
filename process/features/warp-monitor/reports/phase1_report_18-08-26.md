# Phase 1 Report — Swift Reader (Local Only, No Network)
**Date:** 2026-08-18
**Phase:** 1 of 4 — SQLite Reader + Log Tailer + JSON stdout

---

## What Was Built

A Swift Package Manager executable (`warp-monitor`) that:

1. Opens Warp's SQLite database read-only and executes the join query.
2. Tails `~/Library/Logs/warp.log` for OSC 777 Claude events via FSEvents + byte-offset.
3. Maintains a per-session-id state machine for Claude status.
4. Prints a `WarpMonitorState` JSON blob to stdout on every state change.
5. Supports `--once` flag for single-shot JSON output (used for scripting and testing).
6. Supports `--db-path` and `--log-path` overrides for testing with fixture files.

### Files Created

```
mac-app/
├── Package.swift                          SPM package definition
├── Sources/
│   ├── CSQLite/
│   │   ├── module.modulemap               System library wrapper for libsqlite3
│   │   └── sqlite3.h                      Copied from SDK headers
│   ├── WarpMonitor/
│   │   ├── Models.swift                   Swift structs: WarpMonitorState, WarpTab, etc.
│   │   ├── SQLiteReader.swift             Read-only libsqlite3 wrapper + join query
│   │   ├── LogTailer.swift                FSEvents log tailer + OSC 777 parser
│   │   └── StateManager.swift             Orchestrates SQLite + log → JSON state
│   └── WarpMonitorCLI/
│       └── main.swift                     CLI entry point (stdout printer)
└── Tests/
    └── WarpMonitorTests/
        └── LogTailerTests.swift           7 tests: parsing, state machine, timeout, pruning
```

---

## Build Command

```bash
cd /Users/princewagan/television/mac-app
swift build
```

Build output tail:
```
Build complete! (1.23s)
```

Zero errors, zero warnings after fixes.

### Run Commands

Single-shot (prints one JSON blob and exits):
```bash
cd /Users/princewagan/television/mac-app
.build/debug/warp-monitor --once
```

Continuous mode (polls every 5s, prints on changes):
```bash
.build/debug/warp-monitor
```

Test with fixture log file:
```bash
.build/debug/warp-monitor --once --log-path /tmp/test-warp.log
```

---

## Duplicate-Row Diagnosis

### Root Cause

The "8 rows, 6 identical for SUPERLINQ" result described in the task prompt was NOT caused by a faulty SQL join. Investigation confirmed:

**The join produced no duplicates.** The earlier test result reflected the actual state of Warp's database at that time: 6 genuine tabs all in the SUPERLINQ group with the same CWD (`/Users/princewagan/fourlinq-management`), and 2 genuine tabs in FOURLINQ with the same CWD.

Live query result at time of execution:
- `SELECT COUNT(*) total_rows, COUNT(DISTINCT t.id) distinct_tabs FROM tabs t LEFT JOIN ... = 47, 47`
- Zero fanout: every tab maps to exactly one `pane_nodes` row (`is_leaf = 1`).
- Zero `parent_pane_node_id IS NOT NULL` rows → no split pane hierarchy exists in this DB.
- All 47 `pane_nodes` rows have `is_leaf = 1`.

**The query in the plan was already correct.** The `WHERE pn.is_leaf = 1` filter (added to the JOIN clause as `AND pn.is_leaf = 1`) is still present in the implementation as a guard against future split panes, but it changes nothing with current data.

### Decision on Multi-Pane Tabs

Added `AND pn.is_leaf = 1` to the JOIN to ensure only leaf pane nodes are joined. In a future Warp version with split panes:
- Each leaf pane would produce one row per (tab, leaf).
- The `SQLiteReader.buildGroups()` method handles this by deduplicating on `tab_id`, preferring rows with a non-NULL `cwd`, then first-wins deterministically.
- `is_active` and `is_focused` columns exist but are identical (both = 1) for all current rows, so no additional selection is needed now. The code is ready to use `is_active` for selection if split panes appear.

### Interesting Discovery: custom_vertical_tabs_title

`pane_leaves.custom_vertical_tabs_title` is NOT always NULL. Two AUTH tabs have values: "LOGIN" and "USAGE". The title derivation was updated to prefer `custom_vertical_tabs_title` first (this is what Warp shows in its vertical sidebar), then `tabs.custom_title`, then CWD `lastPathComponent`.

---

## Verification Output

### 7 Tab Groups — Confirmed

Running `.build/debug/warp-monitor --once` produces `tab_groups` array with all 7 groups:
- ADVOPARK (7 tabs, cyan, /Users/princewagan/advopark)
- AUTH (10 tabs, no color stored, /Users/princewagan/advopark)
- ENDOCRINE PH (4 tabs, magenta, /Users/princewagan/endocrinePH)
- FOURLINQ (2 tabs, red, /Users/princewagan/fourlinq-1)
- FUNRIDE PH (9 tabs, blue, /Users/princewagan/myriadrun)
- NOKOHI (8 tabs, green, /Users/princewagan/nokohi)
- SUPERLINQ (6 tabs, red, /Users/princewagan/fourlinq-management)

Plus 1 ungrouped tab: `television` (id=47, cwd=/Users/princewagan/television).

### No Duplicate Tabs

Total tabs across groups: 7+10+4+2+9+8+6 = 46 grouped + 1 ungrouped = 47 unique tabs. Each tab has a unique `id`. Zero duplicate tab IDs.

### Log Tailer Tests — 12/12 passing in 0.003s

Tests use `startForTesting()` + direct `readNewLines()` call (no FSEvents, no async waiting).
Temp files in `NSTemporaryDirectory()` are used — the real `~/Library/Logs/warp.log` is never written.

```
✔ Session start event is parsed correctly
✔ tool_complete event is parsed with tool_name
✔ stop_failure event is parsed with error_type
✔ Multiple events in one file are all parsed
✔ Non-claude agent events are ignored
✔ Lines without OSC 777 marker are ignored
✔ stop_failure → warning status transition via state machine
✔ State machine: full transition sequence
✔ 10-minute running timeout downgrades to finished
✔ Timeout does not fire for non-running states
✔ Stale finished session is marked for pruning after 30 minutes
✔ Running session is never considered stale
Test run with 12 tests in 1 suite passed after 0.003 seconds.
```

---

## Deviations from Plan

### 1. SPM instead of Xcode project

**Deviation:** Used Swift Package Manager instead of an Xcode project.

**Reason:** The plan explicitly offered this as an alternative: "use a Swift Package Manager Package.swift executable target if that builds a working MenuBarExtra app more reliably headlessly." Phase 1 requires no MenuBarExtra (stdout only), and SPM builds headlessly without Xcode GUI.

**Impact on Phase 3:** Phase 3 (MenuBarExtra GUI) will require either:
- (a) Wrapping the SPM package in an Xcode project that references it, or
- (b) Adding a `.app` wrapper target to Package.swift using `SwiftUI.App` + `@main` (works on macOS 13+).

Option (b) is feasible for macOS 14+. The user will need Xcode open to run/archive the .app bundle for ad-hoc signing.

**User note:** To get a `.app` bundle from Phase 1 code today, the user can open `mac-app/` folder in Xcode and create a macOS App target that imports the `WarpMonitor` library. All business logic is already in the library target.

### 2. `orphan_sessions` field added to JSON

**Deviation:** Added `orphan_sessions: [ClaudeSession]` to `WarpMonitorState`.

**Reason:** The plan specifies orphan sessions should be "kept in a top-level `orphan_sessions` array in the state blob" (CWD Ambiguity Rule). This field was mentioned in the plan text but not in the Zod schema section.

**Recommendation:** The other agent implementing `lib/schema.ts` should add:
```
orphan_sessions: z.array(ClaudeSession).optional().default([])
```

### 3. Title derivation: custom_vertical_tabs_title first

**Deviation:** Added `pane_leaves.custom_vertical_tabs_title` as the highest-priority title source, ahead of `tabs.custom_title`.

**Reason:** Live data shows `custom_vertical_tabs_title` IS populated ("LOGIN", "USAGE") while `tabs.custom_title` is always NULL. The vertical tabs title is what Warp shows in its sidebar — it is the correct user-visible label.

### 4. Color format is YAML-like, not hex

**Observation (not a schema change):** Warp stores tab group colors as `"---\nColor: cyan\n"` not hex codes. The parser extracts the color name (e.g., "cyan", "magenta", "red", "green", "blue"). The JSON contract says `color: z.string().nullable()` — this is still a string, just a color name rather than a hex code. The phone UI needs to map these names to actual display colors.

---

## Known Limitations for Next Phases

1. **No kqueue on WAL file yet:** Phase 1 uses a 5s polling timer instead of kqueue on `warp.sqlite-wal`. Phase 4 will upgrade to kqueue.
2. **No sleep/wake handler:** Will be added in Phase 4.
3. **No hash-based deduplication:** Every 5s refresh emits stdout. Phase 3 will add hash comparison before push.
4. **No Pusher.swift:** Phase 3 task.
5. **No MenuBarExtra UI:** Phase 3 task.

---

## Phase 1 Status: COMPLETE

- [x] Swift app prints correct JSON to stdout
- [x] All 7 tab groups present in output
- [x] No duplicate tabs
- [x] Log tailer wired and OSC 777 parsing verified via tests
- [x] State machine transitions verified via tests
- [x] Phase report written
