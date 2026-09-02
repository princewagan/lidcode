/**
 * app/api/state/route.ts
 *
 * GET /api/state
 *
 * Phone → Vercel read endpoint.
 * Returns the latest WarpMonitorState stored by /api/push.
 *
 * Auth: Bearer token in Authorization header (same PUSH_SECRET).
 * Cache: no-store — every phone poll must get fresh data.
 * ETag: strong hash of the JSON body; returns 304 when If-None-Match matches.
 *       A 304 is a few bytes instead of a full JSON body and is the primary
 *       mechanism for cutting egress when the state has not changed.
 */

import { NextResponse } from "next/server";
import { createHash } from "crypto";
import { WarpMonitorStateSchema } from "@/lib/schema";
import { readState } from "@/lib/storage";
import { authorizeReadRequest } from "@/lib/auth";

// Prevent Vercel from statically pre-rendering this route.
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  // 1. Auth check — accepts VIEW_PASSWORD or PUSH_SECRET (read path).
  if (!authorizeReadRequest(request)) {
    return NextResponse.json(
      { ok: false, reason: "unauthorized" },
      { status: 401, headers: { "Cache-Control": "no-store" } }
    );
  }

  // 2. Read from Postgres — gracefully handle unconfigured storage.
  const result = await readState();

  if (!result.ok) {
    if (result.reason === "storage_not_configured") {
      return NextResponse.json(
        { ok: false, reason: "storage_not_configured" },
        { status: 503, headers: { "Cache-Control": "no-store" } }
      );
    }
    if (result.reason === "no_data") {
      return NextResponse.json(
        { ok: false, reason: "no_data" },
        { status: 200, headers: { "Cache-Control": "no-store" } }
      );
    }
    // Postgres error
    return NextResponse.json(
      { ok: false, reason: result.reason },
      { status: 500, headers: { "Cache-Control": "no-store" } }
    );
  }

  // 3. Parse and validate the stored blob.
  let parsed;
  try {
    parsed = WarpMonitorStateSchema.parse(result.state);
  } catch {
    return NextResponse.json(
      { ok: false, reason: "state_parse_error" },
      { status: 500, headers: { "Cache-Control": "no-store" } }
    );
  }

  // 4. Compute a strong ETag from the full response body.
  const body = JSON.stringify({ ok: true, state: parsed });
  const etag = `"${createHash("sha256").update(body).digest("hex").slice(0, 32)}"`;

  // 5. Return 304 if the client already has this revision.
  const ifNoneMatch = request.headers.get("If-None-Match");
  if (ifNoneMatch === etag) {
    return new Response(null, {
      status: 304,
      headers: {
        ETag: etag,
        "Cache-Control": "no-store",
      },
    });
  }

  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ETag: etag,
    },
  });
}
