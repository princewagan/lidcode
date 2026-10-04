# LidCode — Web Dashboard

Phone dashboard for [LidCode.app](https://github.com/princewagan/lidcode). See your Mac's lid state, battery, thermals, memory, and agent sessions on your phone.

**Live site:** https://mytelevision.vercel.app

---

## Repository layout

This site now lives inside the `web/` directory of the LidCode Swift repo (`princewagan/lidcode`):

```
lidcode/
  Sources/          ← Swift Mac app (other agents own this)
  web/              ← This Next.js site
    app/
    lib/
    public/
    ...
```

---

## Vercel setup

The Vercel project's **Root Directory** must be set to `web`.

> If you imported the repo before this move (when it was `princewagan/television`), go to
> Vercel → Project → Settings → General → Root Directory and change it to `web`.

### Environment variables (Vercel dashboard)

| Name | Required | Description |
|---|---|---|
| `DATABASE_URL` | Yes | Postgres connection string. Example: `postgres://user:pass@host:5432/dbname?sslmode=require` |
| `PUSH_SECRET` | Yes | Bearer token the Mac app uses to push state (`POST /api/lidcode`). Generate with `openssl rand -hex 32`. |
| `VIEW_PASSWORD` | No | Optional simpler password for the phone dashboard. If unset, `PUSH_SECRET` is used for login. |

**Removed variables:** `SUPABASE_URL` and `SUPABASE_SECRET_KEY` are dead — the site previously used
Supabase client libraries but now talks to Postgres directly via `lib/db.ts`. Do not set these.

---

## Database

Create the `lidcode_state` table using `db/schema.sql`. This works with any Postgres provider
(Supabase, Neon, Railway, self-hosted, etc.). Set `DATABASE_URL` in Vercel to the connection string.

---

## Push payload contract

The Mac app POSTs JSON to `POST /api/lidcode` (Bearer auth).

### Schema version 1 (original)

All fields required unless noted:

```json
{
  "schema_version": 1,
  "pushed_at": "2026-09-02T10:00:00Z",
  "mac_hostname": "prince-mbp",
  "awake_held": true,
  "physical_lid": "closed",
  "hold_expires_at": "2026-09-02T12:00:00Z",
  "hold_elapsed_fraction": 0.42,
  "battery_percent": 83,
  "battery_on_main": false,
  "temperature_celsius": 61.0,
  "temperature_stale": false,
  "claude_five_hour_utilization": 14.0,
  "claude_seven_day_utilization": 7.0,
  "foreign_blocker_count": 3,
  "sessions": [
    {
      "id": "s-1",
      "agent": "claude",
      "project": "lidcode",
      "title": "Port session detection",
      "status": "running",
      "status_changed_at": "2026-09-02T09:58:00Z",
      "last_seen_at": "2026-09-02T09:59:55Z",
      "cwd": "/Users/prince/lidcode"
    }
  ]
}
```

### Schema version 2 (adds memory + claude_accounts)

Both new top-level fields are **optional** — a Mac still on v1 keeps validating and rendering
without them. Making them required would 400 every existing push.

```json
{
  "schema_version": 2,
  "memory": {
    "pressure": "warn",
    "used_percent": 78.3,
    "swap_used_mb": 998.6,
    "swap_total_mb": 2048.0,
    "app": [
      { "name": "Claude", "mb": 6297.0, "count": 11 }
    ]
  },
  "claude_accounts": [
    {
      "key": "prince",
      "label": "PRINCE CLAUDE",
      "five_hour_utilization": 14.0,
      "seven_day_utilization": 7.0,
      "five_hour_resets_at": "2026-09-02T15:00:00Z",
      "seven_day_resets_at": "2026-09-07T00:00:00Z",
      "is_active": true,
      "status": "ok"
    }
  ]
}
```

`pressure` is `"normal" | "warn" | "critical"`. `status` is `"ok"` | `"signed_out"` | `"expired"` or any other string the Mac app may add in future.
`label` is the display name (for example, `ADVO CODEX`), and the reset fields are optional ISO timestamps. For Codex rows, `is_active` marks the profile whose login/session activity is newest.

---

## Demo mode

Preview the dashboard without a Mac push or login:

| URL | What it shows |
|---|---|
| `/?demo=1` | Full v2 fixture — memory warn, 6 app rows, 4 coding accounts, 7 sessions |
| `/?demo=v1` | v1 fixture — no memory/accounts, proves backward compatibility is real |

---

## Development

```bash
cd web
npm install
npm run dev       # http://localhost:3000
npm run typecheck # tsc --noEmit
npm run build     # production build
```

---

## API routes

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/lidcode` | Mac app writes state (Bearer `PUSH_SECRET`) |
| `GET` | `/api/lidcode` | Phone reads state (Bearer `PUSH_SECRET` or `VIEW_PASSWORD`), ETag/304 aware |

> `POST /api/push` and `GET /api/state` serve a different live app — do not touch them.

---

## Verify it is working

```bash
# Should return 401
curl -i https://mytelevision.vercel.app/api/lidcode

# Should return {"ok":true} after first Mac push, or {"ok":false,"reason":"no_data"} before
curl https://mytelevision.vercel.app/api/lidcode \
  -H "Authorization: Bearer <PUSH_SECRET>"

# Test a v1 push (schema_version 1)
curl -X POST https://mytelevision.vercel.app/api/lidcode \
  -H "Authorization: Bearer <PUSH_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{
    "schema_version": 1,
    "pushed_at": "2026-09-02T00:00:00Z",
    "mac_hostname": "test",
    "awake_held": false,
    "physical_lid": "open",
    "battery_on_main": true,
    "temperature_stale": false,
    "foreign_blocker_count": 0,
    "sessions": []
  }'
```
