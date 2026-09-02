/**
 * app/api/push/route.ts
 *
 * POST /api/push
 *
 * Mac app → Vercel write endpoint.
 * Receives the full WarpMonitorState JSON, validates it, and stores it in
 * Supabase Postgres.
 *
 * Auth: Bearer token in Authorization header (same PUSH_SECRET used by /api/state).
 */

import { NextResponse } from "next/server";
import { WarpMonitorStateSchema } from "@/lib/schema";
import { upsertState } from "@/lib/storage";
import { authorizeRequest } from "@/lib/auth";
import { ZodError } from "zod";

// Prevent Vercel from statically pre-rendering this route.
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  // 1. Auth check — timing-safe bearer token comparison.
  if (!authorizeRequest(request)) {
    return NextResponse.json(
      { ok: false, reason: "unauthorized" },
      { status: 401 }
    );
  }

  // 2. Parse and validate body.
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { ok: false, reason: "invalid_json" },
      { status: 400 }
    );
  }

  let parsed;
  try {
    parsed = WarpMonitorStateSchema.parse(body);
  } catch (err) {
    if (err instanceof ZodError) {
      return NextResponse.json(
        { ok: false, reason: "validation_error", errors: err.errors },
        { status: 400 }
      );
    }
    throw err;
  }

  // 3. Write to Supabase — gracefully handle unconfigured storage.
  const result = await upsertState(parsed);

  if (!result.ok) {
    const status = result.reason === "storage_not_configured" ? 503 : 500;
    return NextResponse.json({ ok: false, reason: result.reason }, { status });
  }

  return NextResponse.json({ ok: true });
}
