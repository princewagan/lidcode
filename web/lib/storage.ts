/**
 * lib/storage.ts
 *
 * Direct-Postgres storage for WarpMonitor state — server-side only.
 *
 * Single row in `public.warp_state` table, id = 'current'.
 * Push = INSERT … ON CONFLICT (id) DO UPDATE (upsert).
 * Read = SELECT that row.
 *
 * Returns a "storage_not_configured" sentinel when DATABASE_URL is absent so
 * that `npm run build` succeeds with zero env vars set — same graceful-
 * degradation behaviour the Supabase client previously provided.
 *
 * Parameterised queries only — no string interpolation into SQL, and no named
 * prepared statements (pgbouncer TRANSACTION mode compatibility).
 */

import { getPool } from "./db";

// ---------------------------------------------------------------------------
// Row type — matches the warp_state table schema.
// node-postgres returns timestamptz columns as Date objects at runtime even
// though we declare the type narrowly; we normalise in the return value below.
// ---------------------------------------------------------------------------

interface WarpStateRow {
  state: unknown;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  updated_at: any;
}

const ROW_ID = "current";

// ---------------------------------------------------------------------------
// Public API — signatures and return shapes are unchanged from the Supabase
// implementation so that app/api/push/route.ts and app/api/state/route.ts
// need no edits.
// ---------------------------------------------------------------------------

/**
 * Upsert the current Warp state into Postgres.
 *
 * @param stateBlob  A value that has already been validated by Zod.
 * @returns          `{ ok: true }` on success.
 *                   `{ ok: false, reason: 'storage_not_configured' }` when DATABASE_URL is absent.
 *                   `{ ok: false, reason: string }` on Postgres error.
 */
export async function upsertState(
  stateBlob: unknown
): Promise<{ ok: true } | { ok: false; reason: string }> {
  const pool = getPool();
  if (!pool) return { ok: false, reason: "storage_not_configured" };

  const client = await pool.connect();
  try {
    await client.query(
      `INSERT INTO public.warp_state (id, state, updated_at)
       VALUES ($1, $2, now())
       ON CONFLICT (id) DO UPDATE
         SET state      = EXCLUDED.state,
             updated_at = EXCLUDED.updated_at`,
      [ROW_ID, JSON.stringify(stateBlob)]
    );
    return { ok: true };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, reason: `pg_error: ${message}` };
  } finally {
    client.release();
  }
}

/**
 * Read the current Warp state row.
 *
 * @returns  `{ ok: true, state: unknown, updated_at: string }` on success.
 *           `{ ok: false, reason: 'storage_not_configured' }` when DATABASE_URL absent.
 *           `{ ok: false, reason: 'no_data' }` when no row exists yet.
 *           `{ ok: false, reason: string }` on Postgres error.
 */
export async function readState(): Promise<
  | { ok: true; state: unknown; updated_at: string }
  | { ok: false; reason: string }
> {
  const pool = getPool();
  if (!pool) return { ok: false, reason: "storage_not_configured" };

  const client = await pool.connect();
  try {
    const result = await client.query<WarpStateRow>(
      `SELECT state, updated_at
       FROM public.warp_state
       WHERE id = $1`,
      [ROW_ID]
    );

    if (result.rows.length === 0) {
      return { ok: false, reason: "no_data" };
    }

    const row = result.rows[0];
    return {
      ok: true,
      state: row.state,
      updated_at:
        row.updated_at instanceof Date
          ? row.updated_at.toISOString()
          : String(row.updated_at),
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, reason: `pg_error: ${message}` };
  } finally {
    client.release();
  }
}
