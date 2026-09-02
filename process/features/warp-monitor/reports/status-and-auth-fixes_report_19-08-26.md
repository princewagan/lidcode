# Warp Monitor — Status & Auth Fixes Report
**Date:** 2026-08-19
**Fixes implemented:** Fix 1 (status state machine), Fix 2 (phone UI), Fix 3 (VIEW_PASSWORD auth)

---

## Fix 1 — Status State Machine Bug

### Root Cause

`LogTailer.swift` seeks to the **end** of `~/Library/Logs/warp.log` on startup (by design — we do not re-read history). This means when the daemon first starts, it joins every active session mid-stream. The session_id is not yet in the `sessionMap`, so `ClaudeSessionState` starts at `.idle`.

The original `.idle` branch in `Models.swift` `apply(event:at:toolName:errorType:)` was:

```swift
case .idle:
    status = .running  // always running — the bug
```

This transitioned to `.running` for ANY first event regardless of type. In practice, most first-observed events are terminal events (`idle_prompt`, `stop`, `stop_failure`) because Claude sessions are already complete by the time the daemon starts observing.

**Confirmed impact from live log data (41,947 events in log):**
- 930 terminal events (`idle_prompt`=260, `stop`=247, `stop_failure`=340, `permission_request`=83)
- Old machine: every one of these became `.running` when first observed — causing 13 tabs to show `running` and 0 to show `finished` or `warning`
- Stated distribution from issue: `{"idle":27,"running":13}`

**Simulated proof with last 200 log lines (EOF-seek simulation):**

```
Event                OLD result      NEW result      Correct?
stop_failure         running         warning         YES
stop_failure         running         warning         YES
stop_failure         running         warning         YES
stop                 running         finished        YES
idle_prompt          running         finished        YES
stop_failure         running         warning         YES
idle_prompt          running         finished        YES
stop                 running         finished        YES
idle_prompt          running         finished        YES
stop                 running         finished        YES
```

### Fix Applied

**File:** `mac-app/Sources/WarpMonitor/Models.swift`

The `.idle` branch now maps by event type using the same semantics as the `.running` branch:

```swift
case .idle:
    switch event {
    case .idlePrompt, .stop:
        status = .finished
    case .stopFailure, .permissionRequest:
        status = .warning
    case .sessionStart, .promptSubmit, .toolComplete:
        status = .running
    }
```

No other branches needed correction — `.running`, `.finished`, `.warning` were all correct.

### Plan Deviation

The approved plan's state machine said `(any other event) → running` for the `.idle` branch. This was incorrect given the EOF-seek startup behavior. This is a **deliberate, approved deviation** from the plan spec. The deviation note has been added to the plan file at `process/features/warp-monitor/active/warp-monitor_PLAN_18-08-26.md` under the "Claude Status State Machine" section.

### New Tests Added

9 new tests added to `mac-app/Tests/WarpMonitorTests/LogTailerTests.swift`:

| Test | Verifies |
|---|---|
| `idle + idle_prompt → finished` | Key regression: first event `idle_prompt` must not go to `running` |
| `idle + stop → finished` | First event `stop` → `finished` |
| `idle + stop_failure → warning` | First event `stop_failure` → `warning` |
| `idle + permission_request → warning` | First event `permission_request` → `warning` |
| `idle + session_start → running` | Normal startup path still works |
| `idle + prompt_submit → running` | Normal mid-session join still works |
| `idle + tool_complete → running` | Mid-session tool event still works |
| `idle → finished does not timeout` | 10-min timeout rule is only for `.running` |
| `idle → warning not pruned` | 30-min prune rule exempts `.warning` sessions |

### Verification

```
swift test  →  23 tests in 1 suite passed (0 failures)
             (14 original + 9 new idle-branch tests)

swift build -c release  →  Build complete! (clean)
```

---

## Fix 2 — Phone UI: Status for Every Tab

### Problem

`StatusPill` returned `null` for `idle` status, leaving 27 of 40 tabs with no visible indicator. The page appeared broken.

### Fix Applied

**File:** `components/StatusPill.tsx`

`idle` now renders a quiet gray pill:
```
• No Claude    [gray, de-emphasised relative to active states]
```

All four statuses now always render:
- `running` → Blue pill "Claude running" (pulsing dot)
- `finished` → Green pill "Done" (solid dot)
- `warning` → Amber pill "Needs attention" (pulsing dot)
- `idle` → **Gray pill "No Claude"** (solid dot, de-emphasised) ← new

**File:** `app/page.tsx`

Added a per-page summary count bar above the tab group list. It shows real-time counts of all statuses across all groups and ungrouped tabs:

```
● 3 running  ● 2 needs attention  ● 5 done  · 27 idle
```

- Uses the same color palette as `StatusPill` (blue/amber/green/gray)
- Active states (running/warning) use pulsing dots; done/idle use solid dots
- Counts are computed from `tab_groups.flatMap(tabs) + ungrouped_tabs`
- Only renders when there are tabs to count
- Mobile-first, flex-wrap for narrow screens (390px), no horizontal overflow

### Overflow Regression Check

The existing `flex-1/min-w-0` on growing columns and `shrink-0/whitespace-nowrap` on fixed controls in `TabRow` and `TabGroupCard` are untouched.

---

## Fix 3 — VIEW_PASSWORD for Phone Login

### Design

A new `VIEW_PASSWORD` environment variable is used exclusively for authenticating `GET /api/state` (phone read path). `PUSH_SECRET` is untouched and remains the sole credential for `POST /api/push` (Mac write path).

**Route isolation:**
- `POST /api/push` → uses `authorizeRequest()` → checks only `PUSH_SECRET`
- `GET /api/state` → uses `authorizeReadRequest()` → accepts `VIEW_PASSWORD` first, falls back to `PUSH_SECRET`

**Fallback behavior:**
- If `VIEW_PASSWORD` is not set in the environment: only `PUSH_SECRET` is accepted on the read path
- If neither is set: returns false (401) — no hardcoded defaults, ever

**Timing safety:** Both comparisons use `crypto.timingSafeEqual` via the existing `timingSafeEqual_str` helper in `lib/auth.ts`.

### Files Changed

| File | Change |
|---|---|
| `lib/auth.ts` | Added `verifyReadToken()` and `authorizeReadRequest()` functions; extracted `timingSafeEqual_str` helper |
| `app/api/state/route.ts` | Switched `authorizeRequest` → `authorizeReadRequest` |
| `app/page.tsx` | Updated TokenScreen copy to plain language ("Enter password", "Password" label) |
| `.env.example` | Added `VIEW_PASSWORD=` with explanatory comment |
| `README.md` | Updated env vars table, updated Step 3 setup table |

### Verification Evidence

```
=== Fix 3 Complete Auth Verification (real Supabase) ===

1. GET /api/state with VIEW_PASSWORD:       HTTP 200  PASS
2. GET /api/state with PUSH_SECRET:         HTTP 200  PASS  (back-compat)
3. GET /api/state with wrong password:      HTTP 401  PASS
4. POST /api/push with VIEW_PASSWORD:       HTTP 401  PASS  (must be rejected)
5. POST /api/push with PUSH_SECRET:         HTTP 200  PASS
```

Test was run against `npm run dev` at port 3099 with:
- `PUSH_SECRET` = real value from `.env.local`
- `VIEW_PASSWORD` = `view-test-e639a8714524` (a random test value, not `prince2026`)
- `SUPABASE_URL` / `SUPABASE_SECRET_KEY` = real values from `.env.local`

The literal string `prince2026` does not appear anywhere in the repository. You supply it as `VIEW_PASSWORD` via the Vercel dashboard.

### Security Note (flagged, not blocking)

`prince2026` is a short, guessable password, and the Vercel URL is public. If someone discovers your URL, they can brute-force the password with modest effort. The current design does not implement rate limiting on `/api/state`. This is a known risk for a personal/private dashboard — for now it is acceptable. If you want more protection later, consider adding Vercel Edge Middleware with rate limiting or moving to a longer passphrase.

---

## TypeScript / Build Verification

```
npx tsc --noEmit  →  clean (no output, exit 0)

npm run build     →  ✓ Compiled successfully
                     ✓ Generating static pages (5/5)
                     ✓ Build complete, zero errors or type errors
                     (run with zero env vars set — graceful degradation confirmed)
```

---

## Vercel Environment Variables — Exact Names to Add

| Variable | Where | Action Required |
|---|---|---|
| `PUSH_SECRET` | Already set | No change needed |
| `SUPABASE_URL` | Already set | No change needed |
| `SUPABASE_SECRET_KEY` | Already set | No change needed |
| `VIEW_PASSWORD` | **NEW — must add** | Set to `prince2026` (or your preferred password) in Vercel → Project Settings → Environment Variables → Production |

Only `VIEW_PASSWORD` needs to be added to Vercel. The other three are already configured.

---

## Plan Closeout State

- Fix 1: complete, tested, plan deviation documented
- Fix 2: complete, no regression to overflow fixes
- Fix 3: complete, all 5 auth scenarios verified
- Selected plan: `process/features/warp-monitor/active/warp-monitor_PLAN_18-08-26.md`

Next action: deploy to Vercel by adding `VIEW_PASSWORD` to the Vercel dashboard environment variables.
