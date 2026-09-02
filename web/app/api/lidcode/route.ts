/**
 * app/api/lidcode/route.ts
 *
 * POST /api/lidcode  — LidCode.app → Vercel write endpoint.
 * GET  /api/lidcode  — phone → Vercel read endpoint.
 *
 * POST auth: Bearer PUSH_SECRET only (same as /api/push).
 * GET  auth: Bearer VIEW_PASSWORD or PUSH_SECRET (same as /api/state).
 *
 * GET returns an ETag computed from the full response body and honours
 * If-None-Match with a 304 Not Modified when the state has not changed.
 * This is the primary mechanism for cutting egress on repeated polls.
 *
 * Does NOT import from lib/schema.ts or call upsertState — these are
 * entirely separate from the WarpMonitor push path.
 */

import { NextResponse } from "next/server";
import { createHash } from "crypto";
import { LidCodeStateSchema } from "@/lib/lidcodeSchema";
import { upsertLidCodeState, readLidCodeState } from "@/lib/lidcodeStorage";
import { authorizeRequest, authorizeReadRequest } from "@/lib/auth";
import { ZodError } from "zod";

// Prevent Vercel from statically pre-rendering this route.
export const dynamic = "force-dynamic";

// ---------------------------------------------------------------------------
// POST — LidCode.app → Vercel (write)
// ---------------------------------------------------------------------------

export async function POST(request: Request) {
  // 1. Auth — PUSH_SECRET only.
  if (!authorizeRequest(request)) {
    return NextResponse.json(
      { ok: false, reason: "unauthorized" },
      { status: 401 }
    );
  }

  // 2. Parse body.
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { ok: false, reason: "invalid_json" },
      { status: 400 }
    );
  }

  // 3. Validate against the Frozen Contract schema.
  let parsed;
  try {
    parsed = LidCodeStateSchema.parse(body);
  } catch (err) {
    if (err instanceof ZodError) {
      return NextResponse.json(
        { ok: false, reason: "validation_error", errors: err.errors },
        { status: 400 }
      );
    }
    throw err;
  }

  // 4. Upsert to lidcode_state table.
  const result = await upsertLidCodeState(parsed);

  if (!result.ok) {
    const status = result.reason === "storage_not_configured" ? 503 : 500;
    return NextResponse.json({ ok: false, reason: result.reason }, { status });
  }

  return NextResponse.json({ ok: true });
}

// ---------------------------------------------------------------------------
// GET — phone → Vercel (read)
// ---------------------------------------------------------------------------

export async function GET(request: Request) {
  // 1. Auth — VIEW_PASSWORD or PUSH_SECRET.
  if (!authorizeReadRequest(request)) {
    return NextResponse.json(
      { ok: false, reason: "unauthorized" },
      { status: 401, headers: { "Cache-Control": "no-store" } }
    );
  }

  // 2. Read from Postgres.
  const result = await readLidCodeState();

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
    return NextResponse.json(
      { ok: false, reason: result.reason },
      { status: 500, headers: { "Cache-Control": "no-store" } }
    );
  }

  // 3. Parse the stored blob.
  let parsed;
  try {
    parsed = LidCodeStateSchema.parse(result.state);
  } catch {
    return NextResponse.json(
      { ok: false, reason: "state_parse_error" },
      { status: 500, headers: { "Cache-Control": "no-store" } }
    );
  }

  // 4. Compute a strong ETag from the full response body.
  const responseBody = JSON.stringify({
    ok: true,
    state: parsed,
    updated_at: result.updated_at,
  });
  const etag = `"${createHash("sha256").update(responseBody).digest("hex").slice(0, 32)}"`;

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

  return new Response(responseBody, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ETag: etag,
    },
  });
}
