/**
 * lib/db.ts
 *
 * Shared Postgres pool — server-side only.
 *
 * Targeting the Supabase transaction pooler (pgbouncer, port 6543).
 * Rules for pgbouncer TRANSACTION mode:
 *   - No named prepared statements (use plain parameterised queries only).
 *   - No SET/RESET session state between queries.
 *   - Always call client.release() inside a finally block.
 *
 * The pool singleton is cached on `globalThis` so that Next.js hot-module
 * reloads in development don't accumulate idle connections, and so that warm
 * serverless invocations reuse an already-open connection rather than opening
 * a new one for every request.
 *
 * Returns null when DATABASE_URL is absent so that `npm run build` succeeds
 * with zero env vars set — callers are responsible for handling null.
 */

import { Pool } from "pg";

// Extend globalThis so TypeScript knows the property exists.
declare global {
  // eslint-disable-next-line no-var
  var __pg_pool__: Pool | null | undefined;
}

/**
 * Returns the shared Pool singleton, or null when DATABASE_URL is not set.
 */
export function getPool(): Pool | null {
  if (globalThis.__pg_pool__ !== undefined) {
    return globalThis.__pg_pool__;
  }

  const connectionString = process.env.DATABASE_URL;

  if (!connectionString) {
    globalThis.__pg_pool__ = null;
    return null;
  }

  globalThis.__pg_pool__ = new Pool({
    connectionString,
    // Keep the idle pool tiny for serverless — most invocations complete in
    // well under a second and we want to avoid holding connections open.
    max: 3,
    // Fail fast rather than queuing behind a stuck connection.
    connectionTimeoutMillis: 5_000,
    // Supabase pooler requires SSL; disable certificate validation because
    // the pooler presents a self-signed cert on the supavisor SNI path.
    ssl: { rejectUnauthorized: false },
    // pgbouncer TRANSACTION mode: do not use statement-level caching.
    // Disabling the built-in prepared-statement cache achieves this.
    // (node-postgres calls PREPARE under the hood only when you use
    //  client.query({name, text, values}) — we never do that here.)
  });

  return globalThis.__pg_pool__;
}
