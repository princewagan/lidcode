# Warp Monitor — Implementation Plan
**Feature:** warp-monitor
**Plan file:** `process/features/warp-monitor/active/warp-monitor_PLAN_18-08-26.md`
**Date:** 2026-08-18
**Complexity:** COMPLEX (4 phases, independently verifiable)
**Status:** READY FOR EXECUTE

---

## What This Does (Plain Language)

Your Mac watches your Warp terminal app in the background, reads which projects you have open and whether Claude is working in them, and sends that information to a private website only you can access. You open that website on your phone and see every Warp window, which folder it belongs to, and a green/yellow/red dot for each Claude session — without ever touching your laptop. If your Mac is asleep and the data is stale, the phone page tells you clearly.

---

## Architecture Diagram

```
+------------------+        +---------------------+
|   Warp Terminal  |        |   Warp log           |
|  (GPU-rendered)  |        |  ~/Library/Logs/     |
|  warp.sqlite     |        |  warp.log            |
|  (WAL, read-only)|        |  (OSC 777 events)    |
+--------+---------+        +-----------+---------+
         |                              |
         |  read-only FMDB/libsqlite3   |  tail (FSEvents + byte offset)
         |                              |
         +----------+---------+---------+
                    |
            +-------+--------+
            | Swift Menu Bar |  MenuBarExtra (macOS 26.2)
            |  warp-monitor  |  — polls SQLite every 5s on change
            |   (Mac app)    |  — tails log continuously
            |                |  — builds JSON state in memory
            +-------+--------+
                    |
                    |  HTTPS POST /api/push  (Bearer token)
                    |  push ONLY on state change
                    |  + heartbeat POST every 60s (no change)
                    |
            +-------+--------+
            |  Vercel (Next.js App Router)    |
            |  /api/push   ← write endpoint  |
            |  /api/state  ← read endpoint   |
            |  storage: Upstash Redis (KV)   |
            +-------+--------+
                    |
                    |  HTTPS GET /api/state  (Bearer token in header)
                    |  polling every 10s from phone browser
                    |
            +-------+--------+
            |  Mobile Web    |
            |  Next.js page  |
            |  (phone/tablet)|
            +----------------+
```

---

## Repo Layout — `princewagan/television`

```
television/                          ← git root / Vercel project root
├── .gitignore
├── .env.local                       ← NEVER committed (Bearer secret, Redis URL)
├── .vercelignore                    ← tells Vercel to ignore mac-app/
├── package.json                     ← Next.js app root
├── next.config.ts
├── tsconfig.json
├── tailwind.config.ts
├── postcss.config.mjs
├── app/                             ← Next.js App Router
│   ├── layout.tsx
│   ├── page.tsx                     ← phone-facing dashboard
│   ├── api/
│   │   ├── push/
│   │   │   └── route.ts             ← POST endpoint (Mac → Vercel)
│   │   └── state/
│   │       └── route.ts             ← GET endpoint (phone → Vercel)
├── components/
│   ├── TabGroupCard.tsx
│   ├── TabRow.tsx
│   ├── StatusPill.tsx
│   ├── StaleIndicator.tsx
│   └── NotificationFeed.tsx
├── lib/
│   ├── schema.ts                    ← Zod schema (single source of truth)
│   ├── redis.ts                     ← Upstash Redis client singleton
│   └── auth.ts                      ← Bearer token verification helper
├── process/                         ← RIPER-5 process folder (not deployed)
│   └── features/warp-monitor/...
└── mac-app/                         ← Swift Xcode project (NOT deployed)
    ├── WarpMonitor.xcodeproj/
    ├── WarpMonitor/
    │   ├── WarpMonitorApp.swift      ← @main, MenuBarExtra
    │   ├── MenuBarView.swift         ← SwiftUI popover
    │   ├── StateManager.swift        ← orchestrates SQLite + log → JSON
    │   ├── SQLiteReader.swift        ← read-only libsqlite3 wrapper
    │   ├── LogTailer.swift           ← FSEvents + byte-offset log reader
    │   ├── Pusher.swift              ← HTTPS POST to /api/push
    │   ├── Models.swift              ← Swift structs mirroring JSON schema
    │   └── Info.plist
    └── WarpMonitorTests/
```

### Keeping Vercel Away From mac-app/

`.vercelignore` (file at repo root):
```
mac-app/
process/
```

In the Vercel dashboard → Project Settings → Root Directory: leave blank (use repo root). Vercel detects Next.js via `package.json` + `next.config.ts` at root and will only build the JS portion. The `.vercelignore` ensures it does not attempt to resolve Swift files as assets.

---

## Framework Choice — Next.js App Router (not Vite)

**Chosen: Next.js 15 App Router.**
Justification: Zero-config Vercel deploy with API routes (`app/api/*/route.ts`) in the same project, built-in SSR for the phone page, and no additional adapter config — Vite + Vercel Functions requires `@vercel/vite-plugin` and manual route wiring. One fewer config surface for a personal project.

---

## Storage Choice — Upstash Redis (Vercel KV)

> **DEVIATION NOTE (2026-08-19):** Storage was migrated from Upstash Redis to **Supabase Postgres** per explicit user instruction. The user provided a pre-provisioned Supabase project. `lib/redis.ts` was replaced with `lib/storage.ts` (Supabase-backed). Env vars changed from `KV_REST_API_URL` / `KV_REST_API_TOKEN` to `SUPABASE_URL` / `SUPABASE_SECRET_KEY`. All external API contracts (`/api/push`, `/api/state`, response shapes, auth) are unchanged. See `reports/storage-migration_report_19-08-26.md` for full evidence.

### Why Upstash Redis

| Option | Free tier | Fit |
|---|---|---|
| Vercel KV (Upstash) | 10,000 commands/day, 256 MB | Good if push is event-driven |
| Vercel Postgres | 256 MB, SQL | Overkill for a single JSON blob |
| Vercel Blob | 512 MB | Not a KV store; wrong abstraction |
| Plain file on serverless | Not persistent across invocations | Broken |
| Supabase | 500 MB Postgres | CLI missing, adds a second dashboard |

### Command Budget Analysis

Naive 5-second push: 17,280 SET + 17,280 GET = ~34,560 commands/day → OVER budget.

**Design constraint: push ONLY on state diff + 60s heartbeat.**

- State changes: realistically 50–200 per active work session (Claude events arrive in bursts). Estimate 500 SET commands/day from Mac.
- Phone polling at 10s: 8,640 GET commands/day when phone is open all day (worst case). Realistic: phone open 4h = 1,440 GET commands/day.
- Total daily estimate (active day): ~2,000 commands. Well within 10K free tier.
- Heartbeat: 1 SET per 60s × 16 active hours = 960 heartbeat commands/day. Still within budget.

**Keys used:**
- `wm:state` — the full JSON blob (SET with no TTL; latest wins)
- `wm:updated_at` — epoch seconds (SET alongside state)

No TTL on `wm:state` intentionally; stale detection is done client-side by comparing `wm:updated_at` to `Date.now()`.

---

## JSON State Contract

### Full Literal Example Payload

```json
{
  "schema_version": 1,
  "pushed_at": "2026-08-18T15:17:43Z",
  "mac_hostname": "princes-mbp.local",
  "warp_running": true,
  "tab_groups": [
    {
      "id": "group-uuid-auth",
      "name": "AUTH",
      "color": "#FF453A",
      "collapsed": false,
      "tabs": [
        {
          "id": "tab-uuid-1",
          "title": "television",
          "custom_title": null,
          "cwd": "/Users/princewagan/television",
          "pinned": false,
          "claude_status": "running",
          "claude_sessions": [
            {
              "session_id": "f3cb676c-7c76-485a-98a2-e2691e57586d",
              "project": "television",
              "last_event": "tool_complete",
              "last_event_at": "2026-08-18T15:17:43Z",
              "tool_name": "Bash"
            }
          ],
          "ambiguous_cwd": false
        },
        {
          "id": "tab-uuid-2",
          "title": "advo-api",
          "custom_title": null,
          "cwd": "/Users/princewagan/advo-api",
          "pinned": false,
          "claude_status": "idle",
          "claude_sessions": [],
          "ambiguous_cwd": false
        }
      ]
    },
    {
      "id": "group-uuid-advopark",
      "name": "ADVOPARK",
      "color": "#30D158",
      "collapsed": false,
      "tabs": [
        {
          "id": "tab-uuid-3",
          "title": "frontend",
          "custom_title": null,
          "cwd": "/Users/princewagan/advopark/frontend",
          "pinned": false,
          "claude_status": "warning",
          "claude_sessions": [
            {
              "session_id": "aabbccdd-0000-0000-0000-111122223333",
              "project": "frontend",
              "last_event": "stop_failure",
              "last_event_at": "2026-08-18T14:55:00Z",
              "error_type": "rate_limit"
            }
          ],
          "ambiguous_cwd": false
        }
      ]
    }
  ],
  "ungrouped_tabs": [],
  "notifications": [
    {
      "id": "notif-uuid-1",
      "received_at": "2026-08-18T15:17:43Z",
      "title": "warp://cli-agent",
      "body_raw": "{\"v\":1,\"agent\":\"claude\",\"event\":\"tool_complete\",\"session_id\":\"f3cb676c...\",\"cwd\":\"/Users/princewagan/television\",\"project\":\"television\",\"tool_name\":\"Bash\"}",
      "parsed_event": "tool_complete"
    }
  ]
}
```

### Zod Schema — `lib/schema.ts`

Exact field names and types (no code, but the schema definition the execute agent must implement):

```
ClaudeSession:
  session_id: z.string()
  project: z.string()
  last_event: z.enum(["session_start","prompt_submit","tool_complete","idle_prompt","stop","stop_failure","permission_request"])
  last_event_at: z.string().datetime()
  tool_name: z.string().optional()
  error_type: z.string().optional()

ClaudeStatus: z.enum(["running","finished","warning","idle"])

WarpTab:
  id: z.string()
  title: z.string()
  custom_title: z.string().nullable()
  cwd: z.string()
  pinned: z.boolean()
  claude_status: ClaudeStatus
  claude_sessions: z.array(ClaudeSession)
  ambiguous_cwd: z.boolean()

WarpTabGroup:
  id: z.string()
  name: z.string()
  color: z.string().nullable()
  collapsed: z.boolean()
  tabs: z.array(WarpTab)

WarpNotification:
  id: z.string()
  received_at: z.string().datetime()
  title: z.string()
  body_raw: z.string()
  parsed_event: z.string().nullable()

WarpMonitorState:
  schema_version: z.literal(1)
  pushed_at: z.string().datetime()
  mac_hostname: z.string()
  warp_running: z.boolean()
  tab_groups: z.array(WarpTabGroup)
  ungrouped_tabs: z.array(WarpTab)
  notifications: z.array(WarpNotification).max(50)  // ring buffer, keep last 50
```

---

## Claude Status State Machine

> **DEVIATION NOTE (2026-08-19 — Fix 1):** The `.idle` branch below was implemented as written but is **incorrect** for the actual runtime. `LogTailer` seeks to the END of `warp.log` on startup, so we always join sessions mid-stream. A tab whose first observed event is `idle_prompt` or `stop` means Claude is already done; transitioning to `.running` produces wrong status (confirmed: 13 tabs showed `running`, 0 showed `finished` in live data despite 260 `idle_prompt` events in the log). The corrected implementation in `Models.swift` maps `.idle` by event type (same semantics as `.running` branch): `idle_prompt`/`stop` → `.finished`, `stop_failure`/`permission_request` → `.warning`, `session_start`/`prompt_submit`/`tool_complete` → `.running`. See `reports/status-and-auth-fixes_report_19-08-26.md` for full evidence.

The log tailer maintains a per-`session_id` event stream. The state machine maps log events to the three user-facing statuses, plus `idle`:

```
State: idle (no session_id seen for this cwd)
  → session_start     → running
  → (any other event) → running (treat as in-progress)
  [CORRECTED — see deviation note above: map by event type, not blindly to running]

State: running
  → tool_complete     → running   (still in flight)
  → prompt_submit     → running
  → idle_prompt       → finished
  → stop              → finished
  → stop_failure      → warning
  → permission_request → warning
  → session_start     → running   (new session, reset)

State: finished
  → session_start     → running   (new session opened)
  → prompt_submit     → running   (user sent another message)
  → (any other)       → finished  (ignore stale events)

State: warning
  → session_start     → running   (new session, clear warning)
  → prompt_submit     → running
  → (any other)       → warning   (stay in warning until user acts)
```

**Timeout rule:** If no event has been received for a `session_id` for more than 10 minutes and the last state was `running`, downgrade to `finished` with a `timed_out` flag. This prevents a crashed Claude session from showing as forever-running.

**Display mapping:**
| Internal status | UI label | Pill color |
|---|---|---|
| `running` | Claude running | Blue |
| `finished` | Done / waiting | Green |
| `warning` | Needs attention | Amber |
| `idle` | No Claude | Gray (no pill) |

---

## CWD Ambiguity Rule

When correlating log sessions to tabs:
1. Normalize both sides: `realpath` to resolve symlinks, strip trailing `/`, lowercase is NOT applied (macOS paths are case-preserving).
2. If exactly one tab matches a session's `cwd`: assign normally, `ambiguous_cwd: false`.
3. If zero tabs match: the session is "orphan" — keep it in a top-level `orphan_sessions` array in the state blob (not shown in the main tab list). This happens when Warp has closed the tab but Claude is still running.
4. If two or more tabs match: assign the same `claude_sessions` array to ALL matching tabs, set `ambiguous_cwd: true` on each. The phone UI shows "2+ sessions" instead of a single status pill.

---

## Auth Design

### Mac → Vercel POST (push secret)

- Name: `PUSH_SECRET`
- Mechanism: `Authorization: Bearer <PUSH_SECRET>` header on every POST to `/api/push`
- Value: generate with `openssl rand -hex 32` during setup. Never commit.
- Vercel dashboard: Settings → Environment Variables → `PUSH_SECRET` (production + preview).
- `.env.local`: `PUSH_SECRET=<same-value>`

### Phone → Vercel GET (read secret)

**Chosen: Bearer token in Authorization header, not in URL.**
Tradeoff: URL-embedded secrets appear in server logs, browser history, and shared links. A header-based secret requires the phone to store the token (localStorage is fine for personal use). The phone web page will prompt for the token on first visit, store it in `localStorage`, and attach it as `Authorization: Bearer <token>` on every `/api/state` fetch. This is the same secret as `PUSH_SECRET` — single secret for a single-user app.

- On Vercel: `PUSH_SECRET` covers both directions (no separate read secret for simplicity).
- Phone page: shows a one-time token entry screen if `localStorage.getItem('wm_token')` is null. Token is never sent back to any third party.

### Vercel Env Vars — Exact Names to Paste in Dashboard

| Variable | Source | Description |
|---|---|---|
| `PUSH_SECRET` | `openssl rand -hex 32` | Shared bearer token |
| `KV_REST_API_URL` | Upstash dashboard | Redis REST URL |
| `KV_REST_API_TOKEN` | Upstash dashboard | Redis REST auth token |

The Upstash-sourced names `KV_REST_API_URL` and `KV_REST_API_TOKEN` match the names that Vercel's "Connect to KV" integration auto-injects, so if the user uses the Vercel ↔ Upstash integration they are populated automatically.

---

## SQLite Read Strategy (Swift)

### Opening the Database

- Path constant: `/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite`
- Open flag: `SQLITE_OPEN_READONLY` + URI `?mode=ro` (NOT `immutable=1`; immutable hides uncommitted WAL rows which is where live state lives).
- Use system `libsqlite3.dylib` via `-lsqlite3` linker flag. No third-party DB library needed.
- Do NOT call `sqlite3_wal_checkpoint`. Never write. Never delete the WAL or SHM.

### Query — Full Join (canonical)

The execute agent must implement this query. Written as SQL (reference only, no Swift code):

```sql
SELECT
    tg.id        AS group_id,
    tg.name      AS group_name,
    tg.color     AS group_color,
    tg.collapsed AS group_collapsed,
    t.id         AS tab_id,
    t.custom_title,
    t.pinned     AS tab_pinned,
    t.tab_group_id,
    tp.cwd,
    tp.id        AS pane_id
FROM tabs t
LEFT JOIN tab_groups tg ON t.tab_group_id = tg.id
LEFT JOIN pane_nodes pn ON pn.tab_id = t.id
LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
LEFT JOIN terminal_panes tp ON tp.id = pl.pane_node_id
ORDER BY tg.name NULLS LAST, t.id;
```

**Title derivation rule (in Swift, after query):**
1. If `custom_title` IS NOT NULL and non-empty → use it.
2. Else if `cwd` IS NOT NULL → use `URL(fileURLWithPath: cwd).lastPathComponent`.
3. Else → use `"Tab \(tab_id.prefix(6))"` as fallback.

### Polling Strategy

- Poll trigger: `kqueue` on the WAL file (`warp.sqlite-wal`). When the WAL mtime changes, re-run the query.
- Fallback timer: if no WAL change detected for 10 seconds, run the query anyway (catches edge cases where kqueue misses an event after sleep/wake).
- Deduplication: after query, compare hash of resulting tab list to last pushed hash. Only push if changed.
- Sleep/wake: register for `NSWorkspace.didWakeFromSleepNotification`. On wake, force a re-query and re-push regardless of hash.

### Warp Not Running

- Check `NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable")`. If empty array → set `warp_running: false`, clear `tab_groups`, push a minimal state blob.
- Still push the heartbeat every 60s while Warp is not running so the phone page knows the Mac is alive but Warp is closed.

---

## Log Tailing Strategy (Swift)

### File Handle + Byte Offset

- Open `~/Library/Logs/warp.log` with `FileHandle(forReadingAtPath:)`.
- Seek to end of file on first open (do NOT re-read history; the state machine starts from now).
- Store current byte offset. On each read: seek to offset, read available bytes, parse new lines, advance offset.

### Rotation Handling

Log rotates to `warp.log.old.0`. Detect rotation by:
1. After each read attempt, `stat()` the file. If `st_ino` (inode) differs from when we opened the handle → rotation has occurred.
2. Close old handle. Open new `warp.log`. Seek to byte 0 (new file, read from start).
3. Also check for truncation: if `fileSize < lastOffset` → file was truncated (less common), seek to 0.

### FSEvents vs Timer

Use FSEvents (`DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:)`) to watch `~/Library/Logs/`. Event mask: `.write` and `.rename` (catches rotation). On event, run the read-parse cycle. Also run on a 2-second fallback timer in case FSEvents is delayed post-sleep.

### Parsing OSC 777 Lines

Match lines containing `Received OSC 777 notification:`. Extract the JSON body after `body=`. Parse with `JSONDecoder`. Map `event` field through the state machine. Update the per-`cwd` session map.

Only process lines where `agent == "claude"`. Ignore other OSC 777 senders.

### In-Memory Session Map

`[String: ClaudeSessionState]` keyed by `session_id`. Each entry tracks: `cwd`, `last_event`, `last_event_at`, `project`, optional `tool_name`, optional `error_type`. This map is the source of truth for correlation with SQLite tabs.

Prune sessions that have been in `finished` state for more than 30 minutes to prevent memory growth.

---

## Swift Menu Bar App Design

### MenuBarExtra

```
WarpMonitorApp: App
  MenuBarExtra("Warp Monitor", systemImage: "terminal.fill")
    ContentView()           // popover list of tab groups
```

- Popover shows tab groups and a compressed status. Full detail is on the phone.
- Menu bar icon: `terminal.fill` (SF Symbol). Changes to `terminal.fill` with badge on warning state.
- No Dock icon (`LSUIElement = YES` in Info.plist).

### StateManager (actor or @MainActor class)

Responsibilities:
1. Hold current `WarpMonitorState` in memory.
2. Coordinate SQLite reader and log tailer.
3. Compute diff between previous and current state.
4. Trigger push only on change (or heartbeat timer fires).
5. Update MenuBar UI.

### Pusher

- `URLSession` POST to `https://<your-vercel-url>/api/push`
- Body: `WarpMonitorState` encoded as JSON
- Headers: `Authorization: Bearer <PUSH_SECRET>`, `Content-Type: application/json`
- On 401: show alert in popover "Auth error — check PUSH_SECRET".
- On network error: retry with exponential backoff (1s, 2s, 4s), cap at 32s. Do not spam.
- PUSH_SECRET is read from `~/.warp-monitor.env` file on the Mac (one line: `PUSH_SECRET=<value>`). This file is NOT in the repo.

### Launch at Login

Use `ServiceManagement.SMAppService.mainApp.register()` (macOS 13+). Expose a toggle in the popover. Store preference in `UserDefaults`.

### Xcode Project Settings

- Target: macOS 14.0 minimum (MenuBarExtra requires macOS 13, set 14 for headroom).
- Signing: `CODE_SIGN_IDENTITY = "-"` (ad-hoc). `DEVELOPMENT_TEAM = ""`. `CODE_SIGN_STYLE = Manual`.
- Entitlements: `com.apple.security.network.client` (HTTPS outbound). No sandboxing initially (sandbox breaks reading arbitrary Library paths). Add `com.apple.security.files.user-selected.read-only` as a note but do NOT enable App Sandbox — it would block access to Warp's Group Container path.
- Hardened runtime: YES, but with `com.apple.security.network.client` exception.
- Add `-lsqlite3` to "Other Linker Flags" in Build Settings.

---

## Web App Design (Next.js, Phone)

### Pages

**`app/page.tsx`** — phone dashboard

Layout (mobile-first, Tailwind):
- Top bar: "Warp Monitor" + `StaleIndicator`
- Per `tab_group`: `TabGroupCard` (folder name, color dot, collapsible list of tabs)
- Per `tab`: `TabRow` (title, cwd shortened to last 2 components, `StatusPill`)
- Bottom section: `NotificationFeed` (last 10 notifications, newest first)
- If `warp_running: false`: full-width banner "Warp is closed on Mac"
- If no data at all: "Waiting for first push from Mac"

**`StaleIndicator`:**
- Compute `secondsAgo = Date.now()/1000 - state.pushed_at_epoch`
- < 30s: green dot "Live"
- 30s – 5m: yellow dot "Updated Xs ago"
- > 5m: red banner "STALE — Mac may be asleep. Last update Xm ago."

**TanStack Query usage:**
- `useQuery({ queryKey: ['state'], queryFn: fetchState, refetchInterval: 10_000 })`
- `fetchState` calls `GET /api/state` with `Authorization: Bearer <token>` from localStorage.
- On 401: clear localStorage token, show token entry screen.

### API Routes

**`app/api/push/route.ts`** (POST — Mac side):
1. Verify `Authorization: Bearer <PUSH_SECRET>` against `process.env.PUSH_SECRET`. Return 401 if mismatch.
2. Parse body with `WarpMonitorStateSchema.parse(body)`. Return 400 if invalid.
3. `redis.set('wm:state', JSON.stringify(body))` + `redis.set('wm:updated_at', Date.now()/1000)`.
4. Return `{ ok: true }`.

**`app/api/state/route.ts`** (GET — phone side):
1. Verify Authorization header same as push. Return 401 if mismatch.
2. `const raw = await redis.get('wm:state')`. If null, return `{ ok: false, reason: 'no_data' }`.
3. Parse with schema. Return `{ ok: true, state: parsed }`.
4. Set `Cache-Control: no-store` to prevent CDN caching.

### Components

**`StatusPill`:** Takes `ClaudeStatus`. Renders colored badge.
- `running` → blue pill "Claude running"
- `finished` → green pill "Done"
- `warning` → amber pill "Needs attention" with pulsing dot
- `idle` → nothing (no pill rendered)

**`TabGroupCard`:** Takes `WarpTabGroup`. Renders folder name with color swatch, list of `TabRow`. Collapsible on tap.

**`TabRow`:** Takes `WarpTab`. Shows `title`, shortened `cwd`, `StatusPill`. If `ambiguous_cwd: true`, show "(multiple sessions)" subtitle.

**`NotificationFeed`:** Takes `WarpNotification[]`. Renders most-recent-first list. Each item shows `parsed_event`, `project`, timestamp.

---

## Phased Build Order

### Phase 1 — Swift Reader (local only, no network)

**Goal:** The Swift app can open Warp's SQLite, execute the join query, read the log, and print correct JSON to stdout.

**Steps:**
1. `git init` in `/Users/princewagan/television`. Create `.gitignore`.
2. Create `mac-app/` directory. Open Xcode → New Project → macOS → App. Set bundle ID `ph.advo.warp-monitor`, deployment target macOS 14, team "None" (ad-hoc).
3. Add `LSUIElement YES` to Info.plist. Add `-lsqlite3` to Other Linker Flags.
4. Implement `Models.swift` (Swift structs for the state contract, Codable).
5. Implement `SQLiteReader.swift` using system `libsqlite3`. Hardcode the DB path. Open with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`. Run the join query. Return array of `WarpTab`.
6. Implement `LogTailer.swift`. Open `warp.log`, seek to end, read new lines on FSEvents, parse OSC 777 JSON, update in-memory session map.
7. Implement `StateManager.swift`. Wire SQLiteReader + LogTailer. On change, serialize state to JSON and `print()` to console.
8. Add a temporary `Timer.scheduledTimer(withTimeInterval: 5.0)` in `WarpMonitorApp.swift` to trigger polling and print.
9. Build and run. Observe printed JSON.

**Checkpoint 1 verification:** See Phase 1 Verification Evidence below.

---

### Phase 2 — Vercel App Deployed and Reachable

**Goal:** `https://<project>.vercel.app/api/push` returns 401 (auth required) and `https://<project>.vercel.app/api/state` returns 401. Phone page loads and shows "Waiting for first push from Mac".

**Steps:**
1. In `/Users/princewagan/television` (repo root), run `npm init` → configure for Next.js 15.
2. Install deps: `npm install next react react-dom @upstash/redis zod @tanstack/react-query` and dev deps: `npm install -D typescript tailwindcss postcss autoprefixer @types/react @types/node`.
3. Create `next.config.ts`, `tsconfig.json`, `tailwind.config.ts`, `postcss.config.mjs`.
4. Create `.gitignore` (include `.env.local`, `node_modules/`, `.next/`).
5. Create `.vercelignore` with `mac-app/` and `process/`.
6. Create `lib/schema.ts` — implement all Zod schemas from the contract above.
7. Create `lib/redis.ts` — Upstash Redis client using `KV_REST_API_URL` and `KV_REST_API_TOKEN` from env.
8. Create `lib/auth.ts` — bearer token verification function.
9. Create `app/api/push/route.ts` — POST handler.
10. Create `app/api/state/route.ts` — GET handler.
11. Create `app/layout.tsx`, `app/page.tsx` (minimal: shows "Waiting for first push from Mac").
12. Run `npx vercel dev` locally. Test POST and GET with `curl`.
13. `git add` (never add `.env.local`). `git commit`. `git remote add origin https://github.com/princewagan/television`. `git push -u origin main`.
14. Connect repo to Vercel. In Vercel dashboard: add `PUSH_SECRET`, `KV_REST_API_URL`, `KV_REST_API_TOKEN` env vars (see table above). Deploy.

**Checkpoint 2 verification:** See Phase 2 Verification Evidence below.

---

### Phase 3 — Wire Mac App to Vercel

**Goal:** Opening a new Warp tab causes the phone page to update within 10 seconds.

**Steps:**
1. Create `~/.warp-monitor.env` on the Mac with `PUSH_SECRET=<value>`. Set permissions `chmod 600 ~/.warp-monitor.env`.
2. Implement `Pusher.swift`. Read secret from `~/.warp-monitor.env`. POST `WarpMonitorState` JSON to `https://<project>.vercel.app/api/push`.
3. Wire `StateManager.swift` to call `Pusher` on state diff and on 60s heartbeat timer.
4. Replace the temporary `print()` with the real push call.
5. Implement the full phone page UI: `TabGroupCard`, `TabRow`, `StatusPill`, `StaleIndicator`, `NotificationFeed` components.
6. Wire `app/page.tsx` with TanStack Query polling every 10s.
7. Add the localStorage token entry screen to `app/page.tsx`.
8. Build and sign the Mac app ad-hoc: Product → Archive → Distribute App → Custom → Ad-Hoc. Or: `xcodebuild -scheme WarpMonitor -configuration Release CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" -archivePath build/WarpMonitor.xcarchive archive`.
9. Open Warp. Let the app run. Open the Vercel URL on phone. Verify tabs appear.

**Checkpoint 3 verification:** See Phase 3 Verification Evidence below.

---

### Phase 4 — Polish, Launch-at-Login, Error Handling

**Goal:** App survives Mac sleep, Warp restart, log rotation, and network outages. Launch-at-login works.

**Steps:**
1. Implement sleep/wake handler in `StateManager.swift` (`NSWorkspace.didWakeFromSleepNotification`). On wake: force re-query + push.
2. Implement inode-based log rotation detection in `LogTailer.swift`.
3. Implement session timeout (10-minute rule) in the state machine.
4. Implement exponential backoff retry in `Pusher.swift`.
5. Implement launch-at-login toggle in `MenuBarView.swift` using `SMAppService`.
6. Add `warp_running: false` detection in `StateManager.swift`.
7. Style the phone page for dark mode (Tailwind `dark:` classes). Ensure it is readable on a 390px wide phone screen.
8. Add `<meta name="viewport" content="width=device-width, initial-scale=1">` to `app/layout.tsx`.
9. Add a PWA manifest (`app/manifest.ts`) so phone users can "Add to Home Screen".
10. Final test: simulate all warning scenarios (rate limit, permission request) by replaying a log line manually.

**Checkpoint 4 verification:** See Phase 4 Verification Evidence below.

---

## Verification Evidence Per Phase

### Phase 1 — SQLite Join Verification

Run this in terminal (paste exactly):
```bash
sqlite3 -readonly "/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite" \
  "SELECT tg.name, COUNT(t.id) as tab_count FROM tab_groups tg LEFT JOIN tabs t ON t.tab_group_id = tg.id GROUP BY tg.name ORDER BY tg.name;"
```
**Expected output:** 7 rows including `AUTH`, `ADVOPARK`, `ENDOCRINE PH`, `NOKOHI`, `SUPERLINQ`, `FOURLINQ`, `FUNRIDE PH` each with a non-zero tab count.

Run the full join:
```bash
sqlite3 -readonly "/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite" \
  "SELECT tg.name, t.custom_title, tp.cwd FROM tabs t LEFT JOIN tab_groups tg ON t.tab_group_id = tg.id LEFT JOIN pane_nodes pn ON pn.tab_id = t.id LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id LEFT JOIN terminal_panes tp ON tp.id = pl.pane_node_id LIMIT 10;"
```
**Expected output:** 10 rows, most with NULL `custom_title` and a populated `cwd` (e.g., `/Users/princewagan/television`).

**Phase 1 pass criteria:** Swift app prints a valid JSON blob to stdout with at least 1 tab group matching one of the 7 known names.

### Phase 2 — API Reachable Verification

```bash
# Should return 401
curl -i https://<project>.vercel.app/api/push

# Should return 401
curl -i https://<project>.vercel.app/api/state

# Should return {"ok":true} after push
curl -X POST https://<project>.vercel.app/api/push \
  -H "Authorization: Bearer <PUSH_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{"schema_version":1,"pushed_at":"2026-08-18T00:00:00Z","mac_hostname":"test","warp_running":false,"tab_groups":[],"ungrouped_tabs":[],"notifications":[]}'

# Should return the state just pushed
curl https://<project>.vercel.app/api/state \
  -H "Authorization: Bearer <PUSH_SECRET>"
```
**Phase 2 pass criteria:** All four curl commands return expected responses. Phone URL loads without JS error.

### Phase 3 — End-to-End Verification

1. Mac app running. Open a new Warp tab in the `AUTH` folder.
2. Wait up to 10s.
3. Phone page shows the new tab under `AUTH` folder.
**Expected:** New tab title (derived from CWD) appears. No page refresh needed.

4. Run `claude` in a Warp terminal. Watch for `session_start` in log.
5. Phone page should show `running` pill (blue) for that tab within 10s.

**Phase 3 pass criteria:** Tab appears on phone page. Status pill changes when Claude events fire.

### Phase 4 — Resilience Verification

1. Close MacBook lid for 30s. Open. Phone page should show STALE banner within 30s of lid close (data is 30s+ old). After wake, phone page should recover within 10s.
2. Run `echo '2026-08-18T15:17:43Z [INFO] Received OSC 777 notification: title=Some("warp://cli-agent"), body={"v":1,"agent":"claude","event":"stop_failure","session_id":"test-session","cwd":"/Users/princewagan/television","project":"television","error_type":"rate_limit"}' >> ~/Library/Logs/warp.log`
   Phone page should show amber "Needs attention" pill within 10s.
3. Toggle launch-at-login in popover. Log out and back in. Menu bar icon should appear without manual launch.

---

## Blast Radius / Touchpoints

### Files Created on User's Machine (outside repo)
- `~/.warp-monitor.env` — bearer secret. Created manually. Never in git.
- `/Applications/WarpMonitor.app` — the compiled Mac app (or wherever user copies it).
- Login item registration via `SMAppService` (a LaunchAgent entry in `~/Library/LaunchAgents/`).

### Files Read (read-only, never written)
- `/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/.../warp.sqlite` — read-only.
- `/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/.../warp.sqlite-wal` — read-only.
- `/Users/princewagan/Library/Logs/warp.log` — read-only.

### Permissions Requested from User
- Network access (outbound HTTPS to Vercel) — granted via entitlement, macOS will prompt once.
- File access to Group Container path — NOT sandboxed, so no explicit permission dialog. The user must be the same user who runs Warp.
- Accessibility permission — **NOT requested**. AX API is not used.
- Full Disk Access — **NOT requested**. The Group Container path is accessible to apps run by the same user without FDA.

### External Services Touched
- GitHub repo `princewagan/television` — new repo, user creates it.
- Vercel project — user imports repo. Free Hobby plan.
- Upstash Redis — free tier. User creates account, pastes 2 env vars into Vercel.

### What Is NOT Touched
- Warp's database is never written to.
- No Warp settings are changed.
- No system extensions installed.
- No kernel extensions.
- No Accessibility API.

---

## Top Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Warp DB schema changes on app update (column rename, new join path) | Medium | `SQLiteReader` wraps query in error catch; on failure sets `warp_running: false` with `error: "schema_mismatch"`. Phone shows "Mac reader error". User re-runs Phase 1 verification query to diagnose. |
| Log format changes (OSC 777 JSON fields renamed) | Low-Medium | Log parser is isolated in `LogTailer`. Unknown events are logged to console and ignored; they do not crash the state machine. |
| WAL read staleness (rare: page not yet checkpointed) | Low | Opening with `mode=ro` (not `immutable=1`) gives access to uncommitted WAL rows. Verified live. |
| Same-CWD ambiguity | Low-Medium | Handled explicitly: `ambiguous_cwd: true`, all matching tabs get the same sessions array. UI surfaces it. |
| Mac sleep producing stale phone page | High (common) | StaleIndicator shows STALE banner after 5 minutes of no update. Wake handler forces re-push. |
| Log rotation losing events | Low | Inode-based rotation detection. New file opened from byte 0. A few seconds of events may be lost during rotation; this is acceptable (state machine will catch up on next event). |
| Upstash free tier exhausted (10K commands/day) | Low | Event-driven push + 60s heartbeat keeps daily commands ~2K on active day. |
| Vercel cold start latency on push endpoint | Very low | Push is fire-and-forget from Mac. 500ms cold start is invisible. |
| `custom_title` always NULL | Known/present | Title derived from CWD `lastPathComponent`. Already in the plan. |
| `active_conversation_id` always NULL | Known/present | Not used. Log-based correlation is the only path. |
| Net new Warp tabs have no pane_leaves row yet | Possible | `LEFT JOIN` ensures these tabs still appear with `cwd: null`. Title fallback to `Tab <id_prefix>`. |

---

## Public Contracts

The following interfaces must not change without updating all consumers:

1. **JSON state schema** (`lib/schema.ts`, `Models.swift`) — both sides must agree on field names, types, and `schema_version: 1`. If schema changes, bump to `schema_version: 2` and add a migration in the GET handler.
2. **`/api/push` and `/api/state` endpoints** — URL paths and auth mechanism are fixed. Changing them requires updating the Swift Pusher and any existing phone sessions (localStorage token entry).
3. **CWD normalization rule** — both sides (Swift state builder and any future consumers) must use the same normalization: `realpath`, strip trailing `/`, no case folding.

---

## Dependencies and Sequencing

```
Phase 1 (Swift reader) ──── no external deps, can start immediately
   │
   └──► Phase 2 (Vercel deploy) ──── can run IN PARALLEL with Phase 1
              │
              └──► Phase 3 (wire together) ──── requires BOTH Phase 1 and Phase 2 complete
                        │
                        └──► Phase 4 (polish) ──── requires Phase 3 complete
```

Phase 1 and Phase 2 are independent and can be executed in parallel by the same developer working in two terminals.

### External Blockers

- User must create the GitHub repo `princewagan/television` before Phase 2 Step 13.
- User must create an Upstash Redis database and copy `KV_REST_API_URL` and `KV_REST_API_TOKEN` before Phase 2 Step 14.
- User must connect the Vercel project to the GitHub repo and paste env vars before Phase 2 is verifiable.

---

## Rollback Notes

- **Phase 1:** No system changes. Delete `mac-app/` folder to undo.
- **Phase 2:** Delete the Vercel project and GitHub repo. Remove Upstash DB. No local system changes.
- **Phase 3:** Delete `~/.warp-monitor.env`. Remove the compiled app. Unregister login item by toggling the switch off in the popover before deleting.
- **Phase 4:** Same as Phase 3. `SMAppService.mainApp.unregister()` removes the login item.

---

## Resume and Execution Handoff

### Current State at Plan Creation
- `/Users/princewagan/television` is an EMPTY directory, not yet a git repo.
- No Xcode project exists yet.
- No Vercel project exists yet.
- No Upstash Redis DB exists yet.
- Warp SQLite verified live (2026-08-18). 7 tab groups confirmed. `custom_title` NULL for all tabs.
- OSC 777 log format verified live (2026-08-18). Sample event captured.

### Execute Agent Entry Point

1. Read this plan top to bottom before writing a single line of code.
2. Start with Phase 1 and Phase 2 in parallel (two separate work threads if available).
3. The execute agent must NOT deviate from the JSON schema contract in `## JSON State Contract`. If a field needs to be added, update `lib/schema.ts` AND `Models.swift` atomically.
4. The execute agent must NOT open the SQLite database with `immutable=1`.
5. The execute agent must NOT enable App Sandbox on the Swift target.
6. The execute agent must NOT commit `.env.local` or `~/.warp-monitor.env`.

### Handoff State Markers

When a phase completes, the execute agent should update this section:

- [x] Phase 1 complete — Swift app prints correct JSON to stdout
- [x] Phase 2 complete — Vercel URLs return expected responses
- [ ] Phase 3 complete — Phone page shows live Warp state
      NOTE: Phase 3 code is complete and verified locally (push logic, Pusher.swift, MenuBarApp,
      Zod validation of real Swift output). Final checkbox blocked on user creating Upstash Redis
      + adding Vercel env vars + deploying. See phase3_report_18-08-26.md for full evidence.
- [ ] Phase 4 complete — Launch-at-login works, resilience verified
      NOTE: Phase 4 code is complete and verified locally (14/14 tests, swift build clean,
      tsc clean, npm build clean, .app bundle built and codesigned). Final checkbox blocked on:
      (a) user deploying Upstash + Vercel env vars (same as Phase 3), and
      (b) launching WarpMonitor.app from a GUI session to verify menu bar icon + launch-at-login toggle.
      See phase4_report_18-08-26.md for full evidence.

### Supporting Artifacts

- `/Users/princewagan/television/process/features/warp-monitor/references/` — place any research artifacts (log samples, DB schema dumps) here.
- `/Users/princewagan/television/process/features/warp-monitor/reports/` — place phase completion notes here.

### Warp SQLite Path (exact, copy-paste ready)
```
/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite
```

### Vercel Env Vars Checklist (paste into Vercel dashboard before Phase 2 deploy)
- [ ] `PUSH_SECRET` — generate: `openssl rand -hex 32`
- [ ] `KV_REST_API_URL` — from Upstash dashboard
- [ ] `KV_REST_API_TOKEN` — from Upstash dashboard

### Mac Secret File (create manually, never commit)
```
~/.warp-monitor.env
PUSH_SECRET=<same value as Vercel PUSH_SECRET>
```

---

*Plan written: 2026-08-18. Complexity: COMPLEX. Phases: 4. Next action: EXECUTE Phase 1 + Phase 2 in parallel.*
