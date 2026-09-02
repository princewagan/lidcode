# Phase 2 Report — Vercel App
**Date:** 2026-08-18
**Status:** COMPLETE — all definition-of-done items verified

---

## Files Created

### Config / root
- `.gitignore` — excludes `.env.local`, `.env*.local`, `node_modules/`, `.next/`, `.vercel`, mac-app build outputs
- `.vercelignore` — excludes `mac-app/` and `process/`
- `.env.example` — variable NAMES only, no values
- `package.json` — Next.js 15, TanStack Query v5, Upstash Redis, Zod, Tailwind
- `next.config.ts`
- `tsconfig.json`
- `tailwind.config.ts`
- `postcss.config.mjs`
- `README.md` — plain-language setup guide

### lib/
- `lib/schema.ts` — Zod schema for the full JSON state contract
- `lib/redis.ts` — Upstash Redis singleton; returns null when env vars absent
- `lib/auth.ts` — timing-safe bearer token comparison via `crypto.timingSafeEqual`
- `lib/demoState.ts` — literal fixture data matching the plan's example payload

### app/
- `app/globals.css` — Tailwind base + safe-area insets
- `app/layout.tsx` — root layout with viewport meta, PWA apple-web-app meta
- `app/manifest.ts` — PWA manifest (Add to Home Screen support)
- `app/page.tsx` — full phone UI with TanStack Query polling (10s), localStorage token entry, demo mode, all components wired
- `app/api/push/route.ts` — POST endpoint, auth + Zod validation + Redis write
- `app/api/state/route.ts` — GET endpoint, auth + Redis read + `Cache-Control: no-store`

### components/
- `components/StatusPill.tsx`
- `components/TabRow.tsx`
- `components/TabGroupCard.tsx` (client component, collapsible)
- `components/StaleIndicator.tsx` (client component, auto-updates every 5s)
- `components/NotificationFeed.tsx`

---

## Env Vars the User Must Paste into Vercel

Go to Vercel → Project → Settings → Environment Variables, then add:

| Variable | How to get it |
|---|---|
| `PUSH_SECRET` | Run `openssl rand -hex 32` on the Mac |
| `KV_REST_API_URL` | Upstash dashboard → database → REST API section |
| `KV_REST_API_TOKEN` | Upstash dashboard → database → REST API section |

The names `KV_REST_API_URL` and `KV_REST_API_TOKEN` match what Vercel's Upstash integration auto-injects if the user uses "Connect to KV" in the Vercel dashboard (Storage tab).

---

## Upstash Click-Path (Vercel Dashboard)

1. Go to your Vercel project.
2. Click the **Storage** tab in the top nav.
3. Click **Connect Store** → **Upstash Redis** → **Create New**.
4. Give it a name and pick a region. Click **Create & Continue**.
5. Vercel automatically injects `KV_REST_API_URL` and `KV_REST_API_TOKEN` into your project's environment variables.
6. Redeploy the project (or it takes effect on the next deployment).

Alternatively, create the database at https://upstash.com, copy the two REST values, and paste them manually in Vercel → Settings → Environment Variables.

---

## Curl Verification Output (local dev server, PUSH_SECRET=test-secret-12345)

```
=== TEST 1: GET /api/state no auth ===
HTTP/1.1 401 Unauthorized
cache-control: no-store
content-type: application/json

=== TEST 2: POST /api/push no auth ===
HTTP/1.1 401 Unauthorized
content-type: application/json

=== TEST 3: POST /api/push correct auth + valid payload ===
HTTP/1.1 503 Service Unavailable
content-type: application/json

{"ok":false,"reason":"storage_not_configured"}

(This is correct — no Redis is configured locally. On Vercel with Upstash connected it returns {"ok":true}.)

=== TEST 4: POST /api/push correct auth + malformed body ===
HTTP/1.1 400 Bad Request
content-type: application/json

{"ok":false,"reason":"validation_error","errors":[...7 Zod errors...]}
```

All four tests match expected responses.

---

## Build Output

`npm run build` with ZERO env vars set:

```
▲ Next.js 15.5.23
✓ Compiled successfully in 1646ms
✓ Generating static pages (5/5)

Route (app)                                 Size  First Load JS
┌ ○ /                                    15.4 kB         118 kB
├ ○ /_not-found                            991 B         104 kB
├ ƒ /api/push                              128 B         103 kB
├ ƒ /api/state                             128 B         103 kB
└ ○ /manifest.webmanifest                  128 B         103 kB
```

`npx tsc --noEmit` — clean, zero errors.

---

## Deviations from Plan

### 1. orphan_sessions added to schema (deviation from plan's Zod schema section)
**Reason:** The plan's CWD Ambiguity Rule section explicitly requires a top-level `orphan_sessions` array, but the plan's Zod schema section omits it. Added as `orphan_sessions: z.array(ClaudeSessionSchema).optional()` (optional to maintain backward compatibility with pushes that omit it). This must be reflected in the Swift `Models.swift` Codable struct — the other agent should add `var orphanSessions: [ClaudeSession]? = nil` with `CodingKey` = `orphan_sessions`.

### 2. UI built in Phase 2, not Phase 3 (intentional per orchestrator instructions)
The plan deferred UI to Phase 3. Per user instructions, the full UI was built now. All components from the plan's § Web App Design section are implemented.

### 3. Demo mode (?demo=1) added (intentional per orchestrator instructions)
Not in the original plan. A query-param-triggered client-side demo mode was added using fixture data from `lib/demoState.ts`. No server-side auth is bypassed.

### 4. No Vercel deploy performed (intentional per orchestrator instructions)
The user deploys manually. No `vercel` CLI was invoked.

### 5. Workspace root lockfile warning
Next.js emits a warning about detecting two lockfiles (`/Users/princewagan/package-lock.json` and `/Users/princewagan/television/package-lock.json`). This is cosmetic — the build succeeds. To silence it, add `outputFileTracingRoot: path.join(__dirname)` to `next.config.ts`, or ignore it. The warning does not affect Vercel deployment because Vercel detects the project root from the repo root's `package.json`.

---

## Definition of Done — Checklist

- [x] `npm run build` succeeds with ZERO env vars set
- [x] `npx tsc --noEmit` passes clean
- [x] `GET /api/state` no auth → 401
- [x] `POST /api/push` no auth → 401
- [x] `POST /api/push` correct bearer + valid payload → 503 `storage_not_configured` (no Redis; will be `{"ok":true}` after Upstash connected)
- [x] `POST /api/push` correct bearer + malformed body → 400 with Zod errors
- [x] Demo page renders (verified by `npm run dev` + browser; fixture data renders at 390px)
- [x] Phase report written
- [x] README written

---

## What Remains

- User must create the Upstash database and connect it in Vercel (see click-path above).
- User must deploy to Vercel (push to GitHub, import repo in Vercel dashboard).
- Phase 3: wire the Mac app to call `/api/push`.

---

## Seam fix — 2026-08-19

**Bug:** Swift's `JSONEncoder` omits `nil` Optionals entirely (key absent from JSON). Zod's `.nullable()` requires the key to be present with value `null`. This produced 47 Zod validation errors across three fields: `tab_groups.[].tabs.[].custom_title`, `tab_groups.[].color`, and `ungrouped_tabs.[].custom_title`.

**Fix — Side 1 (`lib/schema.ts`):** Changed `z.string().nullable()` to `z.string().nullable().default(null)` for `custom_title`, `color`, and `parsed_event`. The receiver now tolerates a missing key and normalises it to `null`, so React components never see `undefined`. Inferred TypeScript type remains `string | null`.

**Fix — Side 2 (`mac-app/Sources/WarpMonitor/Models.swift`):** Added custom `encode(to:)` implementations to `WarpTab`, `WarpTabGroup`, and `WarpNotification` using `c.encode(...)` instead of `c.encodeIfPresent(...)` for the three nullable fields. Swift now emits explicit `null` on the wire. `tool_name` and `error_type` (genuinely `.optional()` in Zod) were left as `encodeIfPresent` via the synthesised encoder.

**Verified:** `swift build` clean, `swift test` 12/12 pass, `npx tsc --noEmit` clean, `npm run build` succeeds, Zod validation of live JSON output passes with 0 errors.
- Phase 4: polish, resilience, launch-at-login.
