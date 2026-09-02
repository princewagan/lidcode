# Storage Migration Report — Upstash Redis → Supabase Postgres
**Date:** 2026-08-19
**Status:** COMPLETE — full round-trip verified locally with real Warp data

---

## Why Supabase replaced Upstash

The original plan specified Upstash Redis (Vercel KV) as the storage layer. The user provided a pre-provisioned Supabase Postgres project and explicitly requested the migration. This is a user-approved deviation from the plan.

Advantages of using the already-provisioned Supabase project:
- No new service accounts or dashboards to manage
- SQL table gives a single, inspectable, reproducible schema (`db/schema.sql`)
- Row Level Security (RLS) with zero policies means the anon key is completely locked out — a stronger security posture than a shared Redis token
- The service-role key is only used server-side; it never reaches the browser
- Free tier (500 MB Postgres) is more than adequate for a single-row JSON store

---

## What changed

### Files deleted
| File | Reason |
|---|---|
| `lib/redis.ts` | Replaced by `lib/storage.ts` |

### Files created
| File | Purpose |
|---|---|
| `lib/storage.ts` | Supabase-backed storage module (server-side only). Exposes `upsertState()` and `readState()`. Returns a structured result object rather than throwing, preserving graceful-degradation behaviour. |
| `db/schema.sql` | Reproducible DDL for the `warp_state` table with RLS enabled. Run once in the Supabase SQL editor. |

### Files modified
| File | Change |
|---|---|
| `app/api/push/route.ts` | Imports `upsertState` from `lib/storage` instead of `getRedis` from `lib/redis`. Logic and response shapes unchanged. |
| `app/api/state/route.ts` | Imports `readState` from `lib/storage` instead of `getRedis` from `lib/redis`. Logic and response shapes unchanged. |
| `.env.example` | Replaced `KV_REST_API_URL` / `KV_REST_API_TOKEN` with `SUPABASE_URL` / `SUPABASE_SECRET_KEY`. Variable names only, no values. |
| `README.md` | Step 2 rewritten: Upstash → Supabase setup. Env vars table updated throughout. Troubleshooting updated. |
| `next.config.ts` | Comment updated to reference new env var names. |
| `app/page.tsx` | User-facing `storage_not_configured` error string updated to name the new env vars. |
| `package.json` | Removed `@upstash/redis`. Added `@supabase/supabase-js`. |
| `process/features/warp-monitor/active/warp-monitor_PLAN_18-08-26.md` | Added deviation note at top of Storage Choice section. Historical content preserved. |
| `process/features/warp-monitor/reports/phase3_report_18-08-26.md` | Status line updated: Upstash blocker superseded by this migration. |
| `process/features/warp-monitor/reports/phase4_report_18-08-26.md` | Status line updated: Upstash blocker superseded by this migration. |

### Unchanged (by design)
- `lib/schema.ts` — JSON state schema is not a storage concern
- `lib/auth.ts` — auth is not a storage concern
- `/api/push` URL path, auth mechanism, response shapes
- `/api/state` URL path, auth mechanism, response shapes, `Cache-Control: no-store`
- All Swift source files under `mac-app/Sources/`
- `~/.warp-monitor.env` format (`PUSH_SECRET`, `PUSH_URL`)

---

## Graceful-degradation behaviour preserved

When `SUPABASE_URL` or `SUPABASE_SECRET_KEY` are absent (e.g. during `npm run build` in CI with no env vars):

- `lib/storage.ts` `getSupabaseClient()` returns `null`
- `upsertState()` returns `{ ok: false, reason: 'storage_not_configured' }`
- `readState()` returns `{ ok: false, reason: 'storage_not_configured' }`
- API routes return HTTP 503 with `{"ok":false,"reason":"storage_not_configured"}`
- Build does not fail

This matches the behaviour of the previous `lib/redis.ts` module exactly.

---

## Security properties

- `SUPABASE_SECRET_KEY` is the Supabase `service_role` key. It is server-side only. It bypasses RLS intentionally.
- The `warp_state` table has RLS enabled with **zero permissive policies**. The anon/publishable key cannot read or write any rows.
- `SUPABASE_SECRET_KEY` does not use a `NEXT_PUBLIC_` prefix and is never bundled into client-side JS.
- The key is read from `process.env` at runtime only, inside server-side API route handlers.

---

## Verification evidence

All commands run against `http://localhost:3001` (Next.js dev server, `.env.local` loaded).
Secrets are redacted below — actual values were used during testing.

### TypeScript typecheck
```
npx tsc --noEmit
(exit 0, no output)
```

### Build with zero env vars (graceful degradation)
```
env -i HOME=... PATH=... npm run build
✓ Compiled successfully in 2.7s
✓ Generating static pages (5/5)
Route (app)                    Size  First Load JS
├ ƒ /api/push                  128 B         103 kB
├ ƒ /api/state                 128 B         103 kB
(exit 0)
```

### API contract tests

**TEST 1 — GET /api/state no auth → 401**
```
HTTP/1.1 401 Unauthorized
cache-control: no-store
content-type: application/json
```

**TEST 2 — POST /api/push no auth → 401**
```
HTTP/1.1 401 Unauthorized
content-type: application/json
```

**TEST 3 — POST /api/push wrong bearer → 401**
```
HTTP/1.1 401 Unauthorized
content-type: application/json
```

**TEST 4 — POST /api/push correct bearer + valid payload → 200 `{"ok":true}`**
```json
{"ok":true}
```
This is the key new capability. Redis never worked locally (required Upstash cloud connection).
Supabase Postgres works locally with the real credentials in `.env.local`.

**TEST 5 — POST /api/push correct bearer + malformed body → 400 with Zod errors**
```json
{
  "ok": false,
  "reason": "validation_error",
  "errors": [
    {"received":99,"code":"invalid_literal","expected":1,"path":["schema_version"],"message":"Invalid literal value, expected 1"},
    {"code":"invalid_type","expected":"string","received":"undefined","path":["pushed_at"],"message":"Required"},
    ...
  ]
}
```

**TEST 6 — GET /api/state correct bearer → 200 returning the state just pushed**
```json
{
  "ok": true,
  "state": {
    "schema_version": 1,
    "pushed_at": "2026-08-19T00:00:00Z",
    "mac_hostname": "test-host",
    "warp_running": false,
    "tab_groups": [],
    "ungrouped_tabs": [],
    "notifications": []
  }
}
```

### Swift build and tests
```
cd mac-app && swift build -c release
Build complete! (0.22s)

swift test
✔ Test run with 14 tests in 1 suite passed
```

### Real end-to-end: Swift CLI → local dev server → Supabase → /api/state

Swift `--once` produced a real state blob (`mac_hostname: "prince bigmac"`, tab groups including ADVOPARK, AUTH, ENDOCRINE PH). Piped to `POST /api/push`:
```
{"ok":true}
```

Read back via `GET /api/state`:
```json
{
  "ok": true,
  "state": {
    "schema_version": 1,
    "mac_hostname": "prince bigmac",
    "warp_running": true,
    "tab_groups": [
      {"name": "ADVOPARK", ...},
      {"name": "AUTH", ...},
      {"name": "ENDOCRINE PH", ...},
      ...
    ]
  }
}
```
Real Warp tab data round-tripped through Supabase Postgres successfully.

### RLS security verification

Request using the Supabase **publishable/anon** key (`sb_publishable_<REDACTED>`) directly against the Supabase REST API:
```
GET {SUPABASE_URL}/rest/v1/warp_state?id=eq.current&select=id,state
apikey: sb_publishable_<REDACTED>
Authorization: Bearer sb_publishable_<REDACTED>

Response: []
```
Empty array — not the actual row. RLS is blocking the anon role as intended. The row exists (proven by the successful `/api/state` round-trip using the service-role key), but no anon or unauthenticated client can read it.

---

## Env var names to set in Vercel

These three env vars must be present in the Vercel project (Settings → Environment Variables):

| Variable | Source | Notes |
|---|---|---|
| `PUSH_SECRET` | `openssl rand -hex 32` | Unchanged from original plan |
| `SUPABASE_URL` | Supabase Dashboard → Project Settings → API → Project URL | Replaces `KV_REST_API_URL` |
| `SUPABASE_SECRET_KEY` | Supabase Dashboard → Project Settings → API → service_role key | Replaces `KV_REST_API_TOKEN` |

The Mac-side `~/.warp-monitor.env` file is unchanged — it only needs `PUSH_SECRET` and `PUSH_URL`.

---

## Remaining step (user action required)

Add `SUPABASE_URL` and `SUPABASE_SECRET_KEY` to the Vercel project's environment variables and redeploy. The Supabase table is already provisioned and ready. Once deployed, the full cloud end-to-end will work: Mac app → Vercel → Supabase → phone.
