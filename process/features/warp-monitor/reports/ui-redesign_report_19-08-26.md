# Warp Monitor — Phone Dashboard UI Redesign

**Date:** 2026-08-19
**Scope:** `app/page.tsx`, `app/globals.css`, `app/layout.tsx`, `app/manifest.ts`, `components/**`, `tailwind.config.ts`, `lib/demoState.ts`, new `lib/tabModel.ts`, new `lib/unseen.ts`
**Untouched (frozen contract):** `lib/schema.ts`, `lib/auth.ts`, `lib/storage.ts`, `app/api/**`, `mac-app/**`
**Status:** DONE

---

## 1. The problem the old UI had

The old dashboard rendered one row per tab. On the real machine that is 41 rows, of
which 38 fall back to their folder name as a title. The screen was a wall of
`advopark / ~/advopark / No Claude` repeated seven times, and the one row where
Claude was blocked looked identical to the other forty.

Worse, it implied a precision we do not have. OSC 777 carries no pane id, so a
Claude session attaches to a **folder**, not a tab. Seven identical rows all
showing "Blocked" is not seven blocked things — it is one blocked thing, drawn
seven times.

So the redesign is not a reskin. The unit of display changed.

---

## 2. Core IA decision — cluster by cwd

`lib/tabModel.ts` collapses each group's tabs into one **cluster** per `(group, cwd)`.

| | before | after |
|---|---|---|
| rows on the demo fixture | 30 | 12 |
| rows for the ADVOPARK folder | 7 identical | 1, reading `LOGIN · USAGE · advopark ×7` |

A cluster shows the distinct titles joined, `×N` for the tab count, one path, one
branch, and the single status that is genuinely true for all of them. Expanding it
says so out loud:

> Warp sends no tab id with Claude events, so this status describes the folder — it
> applies to all 6 tabs open here.

Tabs with an empty `cwd` (the Warp Settings pane) each get their own cluster — they
can never correlate to a session, so merging them would be a lie.

Counts everywhere are **per folder, not per tab**. "7 idle" for one quiet directory
would drown the one thing that matters; "1 idle" is the honest number.

---

## 3. How it maps to Warp's visual language

| Warp | here |
|---|---|
| near-black chrome, panels barely raised off the page | `ink.0 #07080a` page → `ink.1 #0e1013` card → `ink.2 #15181c` header |
| hairline separation by light, not shadow | `line #22262d` borders, `.row-divide` inset 5%-white line between rows |
| mono for paths, branches, ids | `font-mono` (SF Mono on iOS) on every path, branch, timestamp, session id |
| colour reserved strictly for state | the entire neutral UI is greyscale; amber/red/blue/green appear only on status |
| tab row: repo · branch · title · agent · status | title + `×N` + status badge on line 1; `~/path` + branch on line 2; agent in the detail |
| light-blue dot on unread tabs | `unseen #7dd3fc` dot in a fixed left rail |
| coloured group bars | 3px rounded colour bar in each group header |

Type is `-apple-system` for UI and SF Mono for machine data. No web fonts, no icon
package — the five glyphs in `components/icons.tsx` are hand-rolled 16px SVG
(chevron, prompt mark, git branch, sign-out, check). Total added runtime deps: zero.

**Dark-only, on purpose.** `color-scheme: dark` is pinned in `globals.css` and `dark`
on `<html>`. This is a companion to a terminal; there is no light Warp to match. It
also deleted ~200 `dark:` variant classes and makes the native password field render
correctly without any styling hacks.

---

## 4. Status legibility

| status | label | treatment | shape |
|---|---|---|---|
| `blocked` / `warning` | **Blocked** | amber, pulsing halo, 2px accent bar down the row edge, reason text surfaced inline | halo ring |
| `error` | **Error** | red, static, `last_query` surfaced inline | **diamond** |
| `running` | **In progress · Bash** | blue, pulsing halo | halo ring |
| `finished` | **Done** / **Done · new** | green, static | solid dot |
| `idle` | **No Claude** | `fg.dim` on a near-transparent chip | hollow ring |

Three escalating mechanisms make blocked/error unmissable:

1. **SummaryBar** headline reports the loudest state present and tints the card to
   match — "3 folders need you", amber.
2. **AttentionPanel** ("Needs you") is a triage lane pinned above the group list
   holding every blocked/errored folder, labelled with its group. It renders
   *nothing at all* when nothing is wrong, which is why it can afford to be loud
   when it appears.
3. Groups whose only content is idle or already-read work **collapse themselves**.
   On the demo fixture, FUNRIDE PH / NOKOHI / UNGROUPED fold to a single census
   line. Quiet recedes so loud can pop.

`idle` never disappears — it keeps a real bordered chip reading "No Claude", just at
the lowest contrast in the palette.

---

## 5. The acknowledgement key (`lib/unseen.ts`)

```
key = `${session_id}|${last_event}|${last_event_at}`
```

**`session_id` is the anchor.** A UUID minted per Claude session: globally unique and
stable across polls. Keying on anything folder-derived (`cwd`, `project`, group name)
breaks the instant a directory is renamed. Keying on `tab.id` would be outright wrong
— sessions attach to folders, not tabs, so the same completion would need N keys for
N tabs and acknowledging one would leave the other six lit.

**`last_event_at` makes it per-completion, not per-session.** A long-lived session
finishes, gets acknowledged, the user sends another prompt, it finishes again: same
`session_id`, new timestamp, new key, dot correctly returns. Acknowledgement means
"I have seen *this* completion", not "I have seen this session". This is the whole
point of the feature and it is the reason the timestamp is in the key at all.

**`last_event` is the belt to that pair of braces.** `last_event_at` is an ISO string
whose precision we do not control — the Swift side has emitted both second- and
millisecond-granularity timestamps. A `permission_request` immediately followed by a
`stop` inside one tick would otherwise collapse to a single key and silently swallow
the second notification. It also makes keys self-describing in devtools, which
matters because these strings are the only debugging surface the feature has.

**Rejected:** hashing the session object. It churns on irrelevant field changes
(`tool_name` updating mid-run) and would resurrect completions the user already
dismissed.

Other decisions:

- Terminal set is `finished | blocked | error`, derived through the same
  `eventStatus()` map the badges use, so a row can never show "Done" while the store
  thinks it is still running.
- A **cluster** is unseen if any of its terminal sessions has an unacknowledged key;
  tapping acks all of them at once.
- Store is `localStorage["wm_seen_v1"]`, `{ key: ackedAtMs }`, bounded on two axes —
  400 entries (oldest acks evicted first) and 30 days. Keys churn on every
  completion, so an unbounded store would grow forever on a long-lived PWA install.
- Every read/write is wrapped: quota errors, private-mode throws and corrupt JSON
  degrade to "no dot", never to a crashed dashboard.
- The hook exposes `ready`, false until localStorage has been read on the client.
  Markers do not render before it flips, so server markup and first client paint
  cannot disagree.
- Tapping a row both acknowledges and expands it. One gesture, one meaning: "I
  looked at this."
- **The attention lane and the group list show the same cluster twice on purpose.**
  Acknowledging in either place clears both, because state is keyed on the session,
  not on the row. Verified below.

**Demo caveat, fixed:** the old fixture rebuilt `last_event_at` from `Date.now()` on
every load, so every reload minted new keys and acknowledgement looked broken when
it was in fact correctly reporting a brand-new completion. Fixture timestamps are now
quantised to a 5-minute bucket. Production is unaffected — the Mac sends real
timestamps that do not move between polls.

---

## 6. Overflow strategy

This has regressed twice, so the rules are explicit and mechanically checked.

1. **Two stacked bands, not one flex row.** The status badge shares a line with the
   title only; path, branch and reason get the full row width beneath it, indented
   `pl-[18px]` past the unseen rail. The first draft put the badge in a column
   spanning all three lines, which cost the path ~100px at 390px and truncated
   `~/advopark` to `~/advopa…`. The folder is the row's identity, so it gets the space.
2. **Growing text columns:** `min-w-0 flex-1 truncate`. `min-w-0` is load-bearing —
   without it a flex item's automatic minimum is `min-content` and long text widens
   the row instead of clipping.
3. **Fixed controls:** `shrink-0 whitespace-nowrap` on every badge, chevron,
   timestamp and count.
4. **Branch chip:** capped at `max-w-[46%]` of the metadata line *and*
   middle-truncated at 17 chars — the JS cap is tuned so the CSS `truncate` never
   fires, because two ellipses on one string reads like a rendering bug. Middle
   rather than end truncation because `feature/` prefixes are noise and the tail
   identifies. Full branch is in the expanded detail and the `title` attribute.
5. **Detail grid:** `grid-cols-[3.75rem_minmax(0,1fr)]`. The `minmax(0,1fr)` is what
   lets a 60-character path `break-all` instead of widening the card.
6. **Raw strings** (`mac_reader_error`, blocked JSON) use `break-all` / `break-words`;
   the `overflow-wrap: break-word` safety net stays on `body`.
7. `overflow-x: hidden` is still *not* set on html/body — it would break the sticky
   header. Containment is structural.

### Bug found and fixed during verification

`line-clamp-2` was silently dead on the blocked/error reason box. The element was a
direct flex child, and Chrome blockifies `display: -webkit-box` to `flow-root` for
flex items, dropping the clamp — leaving a half-cut third line rather than an
ellipsis. Fixed by moving the clamp to an inner span so an outer span absorbs the
flex-item role. Same fix applied in `OrphanSessions.tsx`. Confirmed by computed-style
probe: clamped height 33px (2 lines) against 50px scrollHeight.

---

## 7. Accessibility

- **Never colour alone.** Every badge carries a text label, and every glyph has a
  distinct *shape* as well as a hue: blocked/running = pulsing halo ring, error =
  diamond, done = solid dot, idle = hollow ring. Greyscale users read the label;
  fast scanners read the shape.
- **Contrast, measured not assumed.** Palette was designed against `ink.1` (#0e1013):
  `fg` 15.9:1, `fg.muted` 7.5:1, `fg.dim` 5.0:1. A DOM walk over every text node in
  the fully-expanded UI (resolving the first opaque ancestor background) reports
  **0 failures** against the AA thresholds.
- **Tap targets:** every one of the 22 interactive elements measures ≥44×44px.
  Rows are `min-h-[56px]`, group headers `min-h-[52px]`, the sign-out icon button is
  44×44 with negative margin so it stays visually compact.
- **Motion:** `prefers-reduced-motion: reduce` collapses all animation and transition
  durations globally. Verified by media-feature emulation.
- **Semantics:** `aria-expanded` on every disclosure, `role="alert"` on the reader
  error, `aria-live="polite"` on the summary headline only (it changes only when a
  count changes, so it will not chatter on the 10s poll), `aria-invalid` +
  `aria-describedby` on the password field, `sr-only` "Not checked yet" on row dots —
  suppressed via `decorative` where a visible count already says it.
- **Focus:** `.focus-ring` uses `:focus-visible`, so keyboard users get a ring and
  touch users never see one.

---

## 8. Files

**New**
| file | purpose |
|---|---|
| `lib/tabModel.ts` | status normalisation, cwd clustering, counting, path/branch/age/reason formatting |
| `lib/unseen.ts` | acknowledgement key, bounded localStorage store, `useSeenStore` hook |
| `components/DashboardView.tsx` | the whole dashboard from a `WarpMonitorState` |
| `components/SummaryBar.tsx` | weighted one-second verdict |
| `components/AttentionPanel.tsx` | "Needs you" triage lane |
| `components/GroupCard.tsx` | group panel + `shouldOpenGroup` heuristic |
| `components/SessionRow.tsx` | cluster row + expanded detail |
| `components/StatusBadge.tsx` | `StatusBadge`, `StatusGlyph`, `UnseenDot` |
| `components/AppHeader.tsx`, `TokenScreen.tsx`, `Banners.tsx`, `OrphanSessions.tsx`, `icons.tsx` | |

**Deleted (superseded, no dead code left):** `TabRow.tsx`, `TabGroupCard.tsx`, `StatusPill.tsx`

**Rewritten:** `page.tsx`, `globals.css`, `tailwind.config.ts`, `StaleIndicator.tsx`,
`NotificationFeed.tsx`, `demoState.ts`

Live and demo mode now render the **same** `DashboardView`. The old build had two
divergent trees, so `?demo=1` could look correct while production was broken.

Two behaviours worth flagging as new coverage rather than restyling:

- **Ungrouped tabs now show status.** The old code rendered them as bare titles with
  no `StatusPill` at all — a blocked ungrouped tab was invisible.
- **`orphan_sessions` is now rendered** ("Sessions without a tab"), only when
  non-empty. A blocked session whose folder is closed was previously invisible
  everywhere in the UI.

---

## 9. Verification evidence

### 9.1 `npx tsc --noEmit`
```
TSC CLEAN
```
(exit 0, no output)

### 9.2 `npm run build` with ZERO env vars
`.env.local` moved aside and the build run under `env -i` (only `PATH`/`HOME`):
```
 ✓ Compiled successfully in 1238ms
 ✓ Generating static pages (5/5)

Route (app)                                 Size  First Load JS
┌ ○ /                                    21.2 kB         124 kB
├ ○ /_not-found                            991 B         104 kB
├ ƒ /api/push                              128 B         103 kB
├ ƒ /api/state                             128 B         103 kB
└ ○ /manifest.webmanifest                  128 B         103 kB
+ First Load JS shared by all             103 kB
```
`.env.local` restored afterwards (confirmed present).

### 9.3 Horizontal overflow — 390 / 430 / 768, all three demo variants

**How it was checked:** headless Chrome at each viewport, comparing
`documentElement.scrollWidth` to `clientWidth`, plus a walk over every element in
`body` flagging any whose rect crosses the viewport edge (`right > vw` or `left < 0`).
A pure scrollWidth check can miss a clipped-but-overflowing child, so both run.

```
{"variant":"1",     "width":390,"clientWidth":390,"docScrollWidth":390,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"1",     "width":430,"clientWidth":430,"docScrollWidth":430,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"1",     "width":768,"clientWidth":768,"docScrollWidth":768,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"closed","width":390,"clientWidth":390,"docScrollWidth":390,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"closed","width":430,"clientWidth":430,"docScrollWidth":430,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"closed","width":768,"clientWidth":768,"docScrollWidth":768,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"error", "width":390,"clientWidth":390,"docScrollWidth":390,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"error", "width":430,"clientWidth":430,"docScrollWidth":430,"horizontallyScrollable":false,"offenderCount":0}
{"variant":"error", "width":768,"clientWidth":768,"docScrollWidth":768,"horizontallyScrollable":false,"offenderCount":0}
```
Zero offenders at every width. Screenshots captured at each; visually confirmed
`/Users/princewagan/advopark/apps/mobile-client-web` truncates to
`~/advopark/apps/mobile-client-web` without pushing the card.

### 9.4 Fixture coverage — every required case rendered

| required case | fixture location | rendered as |
|---|---|---|
| running tab | ADVOPARK / `apps/mobile-client-web` | blue `In progress · Bash` |
| blocked tab + `blocked_reason` | ADVOPARK / `advopark` | amber `Blocked`, JSON reason unwrapped to "Wants to run AskUserQuestion — package.json already has a `test` script…" |
| blocked, plain-text reason | SUPERLINQ | amber `Blocked`, "Wants to run: rm -rf node_modules && npm ci --legacy-peer-deps" |
| error tab + `last_query` | TELEVISION | red `Error` + diamond, query surfaced, `rate_limit` in detail |
| finished tab | ENDOCRINE PH, FOURLINQ | green `Done · new` → `Done` after tap |
| idle tab | NOKOHI, FUNRIDE PH, Ungrouped | grey `No Claude`, group auto-collapsed |
| many identically-named tabs | FUNRIDE PH — 6 × `funride` | one row, `funride ×6`; detail reads `funride ×6`, not the name six times |
| mixed titles sharing one cwd | ADVOPARK — 7 tabs | `LOGIN · USAGE · advopark ×7` |
| null `git_branch` | NOKOHI, FUNRIDE / Settings, Ungrouped | branch chip simply absent |
| empty cwd | FUNRIDE / Settings | own row, `no directory`, Path `—`, Pinned Yes |
| long branch | SUPERLINQ `feature/superlinq-billing-webhooks-v2` | `feature/…hooks-v2`, full value in detail + `title` |
| long path | ADVOPARK / mobile-client-web | truncates cleanly |
| `warp_running: false` | `DEMO_STATE_WARP_CLOSED` (`?demo=closed`) | "Warp is closed on your Mac / Showing the last state that was pushed" + stale banner, tab list still rendered |
| `mac_reader_error` | `DEMO_STATE_READER_ERROR` (`?demo=error`) | red banner, raw SQLite string `break-all`, no layout damage |
| orphan session | `archived-2024`, blocked | "Sessions without a tab" panel |

`?demo=1` remains the default and primary entry point; `closed` and `error` were
added as switchable scenarios (demo-only chrome).

### 9.5 Unseen / acknowledge lifecycle

Store cleared, then driven through the real UI:
```
1. fresh (store cleared)        {"dots":8,"summaryChip":"5 new","storeKeys":[]}
   endocrine badge              {"badge":"Done · new"}
2. after tapping endocrine row  {"dots":7,"summaryChip":"4 new",
                                 "storeKeys":["77aa1122-…|stop|2026-08-19T08:36:00.000Z"]}
   endocrine badge              {"badge":"Done"}
3. after reload (persisted)     {"dots":7,"summaryChip":"4 new"}    ← survives reload
```

Re-trigger proven end-to-end through the real code path (not simulated): mark all
seen, then rewind every stored ack by one minute — exactly the store the browser
would hold if the user had acknowledged the *previous* completion of each session and
the Mac has since pushed a newer one.
```
A. fresh install                      {"rowDots":8,"summaryChip":"5 new"}
B. after Mark all seen                {"rowDots":0,"summaryChip":"none"}
C. reload — acks persisted            {"rowDots":0,"summaryChip":"none"}
D. rewound acks to prior completion   {"keys":5}
E. reload — new completions unseen    {"rowDots":8,"summaryChip":"5 new"}   ← re-triggered
F. tapped endocrine row               {"rowDots":7,"summaryChip":"4 new"}   ← clears only that row
```

Cross-lane acknowledgement confirmed visually: tapping the ADVOPARK row inside the
"Needs you" lane cleared the dot on the same cluster in the ADVOPARK group card and
decremented that group header's unseen counter.

Empty case: with nothing unseen, the "N new" chip and the "Mark all seen" button both
disappear and the row is replaced by a quiet `12f · 30t` census.

### 9.6 Password prompt and 401 re-prompt
```
1. no token stored          {"screen":"password prompt","storedToken":null}
2. empty submit             {"screen":"password prompt","error":"Enter your password to continue."}
3. after wrong password     {"screen":"password prompt","storedToken":null,"apiStatuses":[401]}
```
Wrong password → `GET /api/state` 401 → `wm_token` cleared from localStorage →
password screen returns. Flow is byte-for-byte the original logic, restyled only. No
secret was read, printed or written at any point.

### 9.7 Accessibility audit (full UI, all disclosures expanded)
```
{"buttons":22,"tapTargetsUnder44":[],"contrastFailures":[]}
```

### 9.8 Reduced motion
```
prefers-reduced-motion: no-preference  {"animatedEls":13,"sample":["2.4s","2s"]}
prefers-reduced-motion: reduce         {"animatedEls":451,"sample":["1e-06s"]}
```

---

## 10. Open questions

1. **Group auto-collapse after acknowledgement.** A group containing only
   already-read `finished` work collapses on next load. Intentional (read work should
   go quiet), but it means completed sessions need one tap to review. Worth a check
   in real use.
2. **Branch truncation is width-independent.** Capped at 17 chars at every viewport,
   so 768px shows `feature/…hooks-v2` despite having room for the full name. Correct
   for a mobile-first app, trivially improvable with a breakpoint variant if desktop
   use becomes common.
3. **First-run wall of blue.** A brand-new install marks every terminal session
   unseen. Honest ("you have not looked at these"), matches Warp, and one tap of
   "Mark all seen" clears it — but an alternative is to auto-acknowledge everything
   older than N hours on first run.
4. **Demo timestamps rotate every 5 minutes.** Only affects `?demo=`; production keys
   are stable. Flagged so a future reviewer does not read it as a bug.
5. `ambiguous_cwd` remains on the wire and is still deliberately never surfaced.
