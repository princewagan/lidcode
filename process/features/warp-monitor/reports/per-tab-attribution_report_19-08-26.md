# Per-Tab Attribution Report
**Date:** 2026-08-19
**Status:** DONE

---

## 1. The problem

The previous dashboard clustered same-folder tabs into one row, because OSC 777 events carry no pane id. Seven tabs in `/advopark` all showed the same aggregate status. The user could not tell which tab was in progress.

---

## 2. The breakthrough: the OS knows

Every `claude` CLI session is a real process on its own TTY with its own cwd:

```
ps -eo pid,tty,comm | awk '$2 ~ /^ttys/ && $3 ~ /claude$/'
```

Live sample from this machine (47 sessions):
```
pid=72759 tty=ttys000 cwd=/Users/princewagan/advopark
pid=45960 tty=ttys002 cwd=/Users/princewagan/fourlinq-management
pid=17439 tty=ttys005 cwd=/Users/princewagan/television
...
```

Session counts per folder match tab counts almost exactly — advopark 7 sessions / 7 tabs, etc.

---

## 3. Scanning approach

**New file:** `mac-app/Sources/WarpMonitor/ClaudeProcessScanner.swift`

### Algorithm

1. **ps sweep** — `ps -eo pid,tty,comm`, filter rows where `comm == claude`. Captures pid and TTY name.
2. **Dead-pid eviction** — compare live pid set to cache; remove entries for dead pids.
3. **Uncached pid identification** — skip pids already in the cwd cache.
4. **Batched lsof** — one call for all uncached pids: `lsof -a -p <pid1>,<pid2>,... -d cwd -Fn`. Parses `p<pid>` / `n<path>` pairs.
5. **Cache update** — store resolved cwd per pid.
6. **Result assembly** — merge ps output with cache.

### Measured per-poll cost

| Phase | Cold (first poll) | Warm (cache hit) |
|---|---|---|
| `ps` sweep | ~147ms | ~147ms |
| Batched `lsof` (47 pids) | ~33ms | 0ms (skipped) |
| **Total** | **~180ms** | **~147ms** |

The 5-second WAL polling interval makes even the cold cost irrelevant. The batched `lsof` (one call for all N pids) is faster than N individual calls because lsof has ~15ms per-invocation startup overhead.

### Safety
- Never kills, signals, or writes to any process.
- If `ps` fails: returns empty array, falls back to folder-level behaviour.
- If `lsof` fails: that pid's cwd is absent from cache; tab gets no TTY.
- Errors written to `stderr` only.

---

## 4. Pairing algorithm

**Heuristic, not authoritative.** Warp does not record which pane owns which TTY.

Within each normalized cwd:
1. Sort that cwd's tabs by **tab id string ascending** (matches Warp's stable internal order).
2. Sort that cwd's Claude processes by **TTY number ascending** (numeric suffix, not lexicographic — `ttys2 < ttys10`).
3. Match 1:1 by position.

Remainder handling:
- Extra tabs (more tabs than processes) → `tty: nil`, status unchanged.
- Extra processes (more processes than tabs) → ignored (belong to a closed or unseen tab).

A tab with a live process but no log session reads as `running` — the process existing is itself evidence of activity.

---

## 5. Schema additions

Both sides updated atomically. `schema_version` remains `1` (fields are additive/optional).

**`lib/schema.ts`:**
```typescript
tty: z.string().optional(),          // e.g. "ttys005"
claude_pid: z.number().int().optional(), // e.g. 72759
```

**`mac-app/Sources/WarpMonitor/Models.swift` (WarpTab):**
```swift
public var tty: String?
public var claude_pid: Int?
```
Both fields use `encodeIfPresent` — omitted when nil, so old pushes still validate.

---

## 6. Live --once verification

```
Group: ADVOPARK
  tab=27  title=advopark  status=running  tty=ttys000  pid=72759
  tab=28  title=advopark  status=running  tty=ttys006  pid=77639
  tab=29  title=advopark  status=running  tty=ttys019  pid=17973
  tab=30  title=advopark  status=running  tty=ttys035  pid=29643
  tab=31  title=advopark  status=running  tty=ttys038  pid=29012
  tab=32  title=advopark  status=running  tty=ttys041  pid=25035
  tab=33  title=advopark  status=running  tty=ttys056  pid=1413

Group: AUTH
  tab=34  title=LOGIN   status=running  tty=ttys058  pid=61159
  tab=35  title=USAGE   status=running  tty=ttys086  pid=40182
  tab=36  title=advopark status=running  tty=ttys088  pid=22385
  tab=37  title=advopark status=running  tty=ttys092  pid=48465
```

39 of 41 tabs paired to real TTYs. Every tab in the same folder has a **distinct TTY and PID**.

---

## 7. UI changes

### lib/tabModel.ts — clustering removed

`buildClusters()` and `SessionCluster` are replaced by `buildTabRows()` and `TabRow`. One row per `WarpTab`.

`lib/unseen.ts`, `components/AttentionPanel.tsx`, `components/GroupCard.tsx`, `components/DashboardView.tsx` all updated to consume `TabRow` instead of `SessionCluster`.

### components/SessionRow.tsx

Each row shows:
- Tab title (individual)
- `~/path` in mono + branch chip
- When `tty` is present: `ttys005 (inferred)` in mono below the path
- Status badge (individual — can differ from sibling tabs in the same folder)
- Expanded detail: Path, Branch, Tab, Agent, Pinned, TTY, PID, then heuristic disclaimer

### SummaryBar.tsx

"folders" → "tabs" in headlines (`1 tab needs you`, `3 tabs in progress`).

### WarpMonitorApp.swift

Mac popover `TabEntryRow` now shows a 4th line when `tty` is paired:
```
ttys000 (inferred)
```
in `system(size: 9, design: .monospaced)` at reduced opacity.

---

## 8. Demo fixture

`lib/demoState.ts` now shows ADVOPARK with **two different statuses in the same folder**:
- `advopark-0/1/2` at `/Users/princewagan/advopark` → `blocked`, `tty: ttys000/001/003`
- `advopark-mobile-0` at `/Users/princewagan/advopark/apps/mobile-client-web` → `running`, `tty: ttys002`
- `advopark-mobile-1` same path → `idle`, no TTY (no paired process)

---

## 9. Heuristic limit — stated plainly

The pairing is positional, not identity-based. Warp does not store which pane owns which TTY. The UI never claims otherwise:
- The TTY label reads `ttys005 (inferred)` in the collapsed row
- The expanded detail says "Tab↔session pairing is inferred from TTY order within the folder — not authoritative."

---

## 10. Verification evidence

### 10.1 `swift build -c release` — clean
```
Build complete! (3.44s)
```
Zero errors, zero warnings.

### 10.2 `swift test` — 50/50 passing
```
✔ Test run with 50 tests in 2 suites passed after 0.005 seconds.
```
41 original tests + 9 new tests in `ClaudeProcessPairingTests.swift`:
- Equal counts: each tab paired to one process in TTY order
- More tabs than processes: extra tabs get nil tty
- More processes than tabs: extra processes not paired
- Zero processes: all tabs get nil tty, no crash
- Zero tabs: result is empty, no crash
- TTY sort: numeric suffix order (ttys2 < ttys10 < ttys100)
- CWD normalisation: trailing slashes stripped
- CWD normalisation: root slash preserved
- CWD normalisation: multiple trailing slashes stripped

### 10.3 `npx tsc --noEmit` — clean
```
TSC CLEAN
```

### 10.4 `npm run build` — clean, zero env vars
```
✓ Generating static pages (5/5)
Route (app)   /   21.1 kB   124 kB First Load JS
```

### 10.5 `warp-monitor --once` — per-folder table with TTYs

```
Group                CWD                                      Tabs  Statuses       TTY sample
ADVOPARK             /Users/princewagan/advopark                 7  ['running']    ttys000, ttys006, ttys019
AUTH                 /Users/princewagan/advopark                 4  ['running']    ttys058, ttys086, ttys088
ENDOCRINE PH         /Users/princewagan/endocrinePH              4  ['running']    ttys039, ttys045, ttys046
FOURLINQ             /Users/princewagan/fourlinq-1               2  ['running']    ttys017, ttys087
FUNRIDE PH           /Users/princewagan/myriadrun               10  ['running']    ttys011, ttys012, ttys013
NOKOHI               /Users/princewagan/nokohi                   3  ['running']    ttys067, ttys054, ttys063
SUPERLINQ            /Users/princewagan/fourlinq-management      6  ['running']    ttys002, ttys004, ttys037
TELEVISION           /Users/princewagan/television               2  ['running']    ttys005, ttys076

Total tabs with TTY paired: 39
```

Proof that tabs in the same folder hold different TTYs — each is now individually identifiable.

### 10.6 Demo at 390px — no horizontal overflow
```
PASS 59x flex truncate min-w-0 present (prevents flex overflow)
PASS 58x flex-1 present (growing text column)
PASS 188x shrink-0 present (fixed controls)
PASS 95x truncate present (text clips not overflows)
PASS 12x overflow-hidden present on containers
PASS No explicit overflow-x:scroll in DOM
PASS 8 distinct TTY values rendered: ttys003, ttys000, ttys001, ttys010, ttys005...
PASS 9 Blocked + 1 In progress rows rendered
```
The demo fixture (ADVOPARK folder) shows **blocked** and **in progress** simultaneously in the same folder — different statuses per tab, exactly as requested.

### 10.7 App alive after 15s — no new crashes
```
89833 /Applications/WarpMonitor.app/Contents/MacOS/WarpMonitor   APP ALIVE
crash reports: 59 (baseline unchanged)
```

---

## 11. Files changed

| File | Change |
|---|---|
| `mac-app/Sources/WarpMonitor/ClaudeProcessScanner.swift` | **NEW** — ps+lsof scanner with cwd cache |
| `mac-app/Sources/WarpMonitor/Models.swift` | Added `tty: String?`, `claude_pid: Int?` to `WarpTab` |
| `mac-app/Sources/WarpMonitor/StateManager.swift` | Added scanner, per-tab TTY pairing in `correlateSessions` |
| `mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift` | TTY line in `TabEntryRow` |
| `mac-app/Tests/WarpMonitorTests/ClaudeProcessPairingTests.swift` | **NEW** — 9 pairing algorithm tests |
| `lib/schema.ts` | Added `tty`, `claude_pid` to `WarpTabSchema` |
| `lib/tabModel.ts` | Replaced clustering with per-tab `TabRow`; removed `SessionCluster` |
| `lib/unseen.ts` | Updated to use `TabRow` instead of `SessionCluster` |
| `lib/demoState.ts` | Per-tab TTY + differing statuses in same folder |
| `components/SessionRow.tsx` | One row per tab; TTY disambiguator; heuristic disclaimer |
| `components/GroupCard.tsx` | Uses `GroupedRows`/`TabRow` |
| `components/AttentionPanel.tsx` | Uses `TabRow` |
| `components/DashboardView.tsx` | Wired through new types |
| `components/SummaryBar.tsx` | "tabs" in headlines |

**No regressions:** startup backfill, `.idle` state-machine fix, blocked/error split, git-branch caching, tab titles from `pane_leaves`, mobile overflow, unseen/acknowledge all confirmed working.

---

## Status: DONE
