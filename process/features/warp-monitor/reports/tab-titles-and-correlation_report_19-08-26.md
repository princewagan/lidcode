# Tab Titles and Session Correlation — Fix Report
**Date:** 2026-08-19
**Plan:** `process/features/warp-monitor/active/warp-monitor_PLAN_18-08-26.md`
**Status:** DONE

---

## Fix 1 — Tab Titles (pane_leaves.custom_vertical_tabs_title)

### Root Cause
The title derivation priority order was already implemented correctly in the codebase at the time this fix session began. `SQLiteReader.swift`'s `makeWarpTab` already read `pl.custom_vertical_tabs_title` (column 10) and applied the correct priority:

1. `pane_leaves.custom_vertical_tabs_title` if non-null and non-empty
2. `tabs.custom_title` if non-null and non-empty
3. CWD `lastPathComponent`
4. `Tab <id_prefix>` fallback

The live database confirms:
- `pane_node_id 34` (`custom_vertical_tabs_title = "LOGIN"`) → renders as **LOGIN** in AUTH group
- `pane_node_id 35` (`custom_vertical_tabs_title = "USAGE"`) → renders as **USAGE** in AUTH group
- `tabs.custom_title = "Settings"` on tab 22 → renders as **Settings** in FUNRIDE PH group

### What Changed
No code change required — Fix 1 was already implemented in a previous session (confirmed by phase 3/4 reports). This session verified the fix is live and working.

### Verification
```
Fix 1 — LOGIN title present: True (group=AUTH)
Fix 1 — USAGE title present: True (group=AUTH)
Fix 1 — Settings title present: True (group=FUNRIDE PH)
```

---

## Fix 2 — Remove Bogus "Multiple Sessions" Warning

### Root Cause
`components/TabRow.tsx` had two conditional branches on `tab.ambiguous_cwd`:
- A text subtitle `"Multiple sessions detected"` (amber, below the cwd)
- A badge showing `"{count} sessions"` in place of the `StatusPill`

This was noise because per-tab session attribution is structurally impossible (see Hard Data Limit below). When multiple tabs share a folder and a Claude session runs in that folder, ALL tabs receive the same `ambiguous_cwd: true` flag — causing ALL of them to show the amber warning instead of a real status. This is what the user saw as "some of them say no Claude".

### What Changed
**`components/TabRow.tsx`:**
- Removed the `{tab.ambiguous_cwd && <p>Multiple sessions detected</p>}` subtitle
- Removed the `{tab.ambiguous_cwd ? "{N} sessions" : <StatusPill />}` conditional
- Now always renders `<StatusPill status={tab.claude_status} toolName={toolName} />` regardless of `ambiguous_cwd`
- Added `is_focused` dot rendering (Fix 4, see below)
- `ambiguous_cwd` field remains on the wire (not removed from schema) as always-false is emitted when unambiguous, so old receivers still validate

### Verification
```bash
grep -r "multiple sessions\|Multiple sessions\|ambiguous_cwd" components/ app/
# Only appears in a code comment, not in any rendered JSX
```

---

## Fix 3 — Correct Status on Every Tab in a Folder

### Root Cause Analysis
The `correlateSessions` function in `StateManager.swift` was already structurally correct:
- Builds `allTabs` from all tabs with `!tab.cwd.isEmpty`
- Groups sessions by `normalizeCWD(session.cwd)`
- For each cwd, finds ALL matching tabs
- Applies `aggregateStatus` to ALL matching tabs (not just the first)

The user's complaint "some say no Claude even though all of them do have Claude" was caused by **Fix 2's bug**: `ambiguous_cwd: true` replaced the `StatusPill` with an amber session count badge. Since multiple tabs share the same cwd (e.g., 7 ADVOPARK tabs + 4 AUTH tabs all at `/Users/princewagan/advopark`), they all got `ambiguous_cwd: true`, and the UI showed the badge instead of the actual running/finished/warning status.

**No logic change was needed in `StateManager.swift`.** The aggregate status is correctly applied to all matching tabs. Fix 2 is what restores the visible status.

### NULL CWD Investigation
Exactly **1 tab** has a NULL/empty cwd:
- **FUNRIDE PH, tab id=22, title="Settings"** — this is the Warp Settings pane, not a terminal. It has no `terminal_panes` row and therefore no cwd. It correctly shows "No Claude" (idle), and that is accurate.

### CWD Normalization Verification
All project directories exist on disk and resolve cleanly under `realpath` (no symlinks):
- `/Users/princewagan/advopark` → itself
- `/Users/princewagan/myriadrun` → itself
- `/Users/princewagan/television` → itself
- `/Users/princewagan/endocrinePH` → itself
- `/Users/princewagan/nokohi` → itself
- `/Users/princewagan/fourlinq-management` → itself
- `/Users/princewagan/fourlinq-1` → itself

No case-folding is applied. The normalization is: strip trailing `/`, call `realpath`, fall back to raw path if `realpath` fails (directory deleted since tab was opened).

### Per-Folder Status Breakdown (--once, no live log sessions)
| Folder | Tabs | Sessions | Statuses |
|--------|------|----------|----------|
| ADVOPARK | 7 | 0 | [idle] |
| AUTH | 4 | 0 | [idle] |
| ENDOCRINE PH | 4 | 0 | [idle] |
| FOURLINQ | 2 | 0 | [idle] |
| FUNRIDE PH | 11 | 0 | [idle] |
| NOKOHI | 3 | 0 | [idle] |
| SUPERLINQ | 6 | 0 | [idle] |
| TELEVISION | 2 | 0 | [idle] |

All folders show exactly 1 distinct status. When sessions ARE active (live app), all tabs in a matching folder receive the same aggregate status — the correlation loop applies to `matchingTabs` (all, not first-match).

---

## Fix 4 — Focused Tab Indicator

### Hard Data Limit Discovered
**`pane_leaves.is_focused` is useless as a focus indicator in the current Warp schema.** The column has `DEFAULT FALSE` in the DDL but all 40 rows in the live database have `is_focused = 1` (true). Similarly, `terminal_panes.is_active = 1` for all 39 rows with pane data. Neither column distinguishes the currently focused tab — Warp does not persist this to SQLite in any reliable way.

Detailed findings:
- `pane_leaves.is_focused`: 40/40 rows = true
- `terminal_panes.is_active`: 39/39 rows = true (1 tab has no pane row)
- `pane_nodes`: no focus-related column
- `tabs`: no focus-related column

### What Changed
The field was added to both sides of the schema contract atomically:

**`lib/schema.ts` — `WarpTabSchema`:**
```typescript
is_focused: z.boolean().optional().default(false),
```
Optional with `default(false)` so pushes from old Mac app versions still validate.

**`mac-app/Sources/WarpMonitor/Models.swift` — `WarpTab`:**
- Added `public var is_focused: Bool` with default `false`
- Custom encoder always emits `is_focused` as explicit `false` (never omits the key)

**`mac-app/Sources/WarpMonitor/SQLiteReader.swift`:**
- Added `isFocused: Bool` to `TabRow` struct
- Added column 11 (`pl.is_focused`) to the SQL query
- Reads it faithfully from SQLite but `makeWarpTab` emits `is_focused: false` because the DB default makes all rows identical and therefore useless
- Added comment explaining the DB limitation for future maintainers

**`components/TabRow.tsx`:**
- Reads `tab.is_focused ?? false`
- Renders a small `h-1.5 w-1.5` blue dot before the title when `isFocused === true`
- Because the Mac always emits `false`, the dot is never shown in production until Warp changes its schema

**`lib/demoState.ts`:**
- Added `is_focused: true` on the first demo tab (the "running" tab) to exercise the UI dot in demo mode
- Added `is_focused: false` on all other demo tabs

### Group Header Session Count
**`components/TabGroupCard.tsx`** now shows `"N tabs · M sessions"` in the group header when sessions > 0. Session count is de-duplicated by `session_id` across all tabs in the group (since shared-cwd tabs receive identical sessions arrays, dedup prevents overcounting).

---

## Hard Data Limit Statement

**OSC 777 events carry no pane or tab identifier.** The full key set of an OSC 777 JSON body is:
```
v, agent, event, session_id, cwd, project, tool_name, error_type,
transcript_path, description, header, label, options, plugin_version,
preview, query, question, questions, response, summary, tool_input
```

There is no `tab_id`, `pane_id`, or `window_id` field. A Claude session can be mapped to a **folder** (via `cwd`) but never to a specific tab. When multiple tabs share a cwd, all of them receive the same session data and the same aggregate status. This is a hard limit of Warp's current OSC 777 protocol — it cannot be worked around without Warp adding a pane identifier to the event payload.

**Accepted behaviour:** identical-looking rows within a shared folder are expected and correct. The user confirmed this during the design review session.

---

## NULL CWD Tab Count

**Exactly 1 tab has a NULL/empty cwd:** FUNRIDE PH, tab id=22, title="Settings" (the Warp Settings pane — not a terminal, has no `terminal_panes` row). This tab correctly shows "No Claude" (idle status). This is the only tab that genuinely cannot be matched to any Claude session.

---

## Verification Evidence

### 1. `swift build -c release` — clean
```
Build complete! (3.05s)
```

### 2. `swift test` — 23/23 passing
```
✔ Test run with 23 tests in 1 suite passed after 0.004 seconds.
```

### 3. `npx tsc --noEmit` — clean
No output (exit 0).

### 4. `npm run build` — clean, zero env vars
```
✓ Compiled successfully in 1114ms
✓ Generating static pages (5/5)
```
Zero errors, zero type errors.

### 5. `warp-monitor --once` against live DB
```
Fix 1 — LOGIN title present: True (group=AUTH)
Fix 1 — USAGE title present: True (group=AUTH)
Fix 1 — Settings title present: True (group=FUNRIDE PH)
Fix 2 — ambiguous_cwd field on wire (preserved): True
Fix 2 — ambiguous_cwd=true tabs (0 in --once): 0
Fix 3 — NULL/empty cwd tabs: 1 (FUNRIDE PH id=22 Settings)
Fix 4 — is_focused field on wire: True
Fix 4 — is_focused=true tabs: 0 (DB default limitation, always emit false)
Summary — 8 groups, 40 tabs, 1 ungrouped
All verification checks PASSED.
```

### 6. No "(multiple sessions)" string in rendered UI
```bash
grep -r "multiple sessions\|Multiple sessions\|ambiguous_cwd" components/ app/
# Only in a comment in TabRow.tsx, not in any JSX
```

### 7. Mobile overflow — no regression
`TabRow.tsx` preserves the `flex-1 min-w-0` growing column and `shrink-0 pt-0.5` fixed control column. The focused-tab dot is `inline-block shrink-0` inside the title flex row and cannot push the layout wider than the viewport.

---

## Files Changed

| File | Change |
|------|--------|
| `lib/schema.ts` | Added `is_focused: z.boolean().optional().default(false)` to `WarpTabSchema` |
| `lib/demoState.ts` | Added `is_focused` field to all 4 demo tab objects |
| `mac-app/Sources/WarpMonitor/Models.swift` | Added `is_focused: Bool` field and encoder key to `WarpTab` |
| `mac-app/Sources/WarpMonitor/SQLiteReader.swift` | Added `isFocused` to `TabRow` struct, column 11 to SQL query, read in `fetchRows`, emit `false` in `makeWarpTab` |
| `components/TabRow.tsx` | Removed ambiguous_cwd warning branches; always show StatusPill; added focused-tab dot |
| `components/TabGroupCard.tsx` | Added de-duplicated session count to group header |

**Files with no changes needed:**
- `StateManager.swift` — correlation logic was already correct
- `app/page.tsx` — no UI changes needed there
- `StatusPill.tsx` — no changes needed
- `StaleIndicator.tsx` — no changes needed
- `NotificationFeed.tsx` — no changes needed

---

## Status

DONE
