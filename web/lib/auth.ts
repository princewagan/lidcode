/**
 * lib/auth.ts
 *
 * Bearer token verification using a timing-safe comparison.
 * Using === for secret comparison is vulnerable to timing attacks.
 * crypto.timingSafeEqual prevents that.
 *
 * Auth model (two routes, two credential sets):
 *
 *   POST /api/push  — Mac → Vercel write path.
 *     Accepts ONLY PUSH_SECRET.  VIEW_PASSWORD is never accepted here.
 *
 *   GET /api/state  — phone → Vercel read path.
 *     Accepts VIEW_PASSWORD (if set) OR PUSH_SECRET.
 *     If VIEW_PASSWORD is unset, falls back to PUSH_SECRET only.
 *     Never falls back to any hardcoded default.
 */

import { timingSafeEqual } from "crypto";

/**
 * Extracts the bearer token from an Authorization header value.
 * Returns null if the header is missing or not a Bearer scheme.
 */
export function extractBearerToken(
  authHeader: string | null | undefined
): string | null {
  if (!authHeader) return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

/**
 * Timing-safe equality check between two strings.
 * Returns false if either is empty or they differ in length/content.
 */
function timingSafeEqual_str(a: string, b: string): boolean {
  if (!a || !b) return false;
  const bufA = Buffer.from(a, "utf8");
  const bufB = Buffer.from(b, "utf8");
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

/**
 * Compares a candidate token against the expected PUSH_SECRET using a
 * constant-time comparison to prevent timing attacks.
 *
 * Returns false when PUSH_SECRET is not configured — the route handlers
 * treat a missing secret as a misconfiguration and should 500, but we
 * leave that decision to the caller so auth.ts stays pure.
 *
 * Use this for the PUSH route only.
 */
export function verifyToken(candidate: string | null): boolean {
  const expected = process.env.PUSH_SECRET;
  if (!expected || !candidate) return false;
  return timingSafeEqual_str(candidate, expected);
}

/**
 * Verifies a candidate token for the READ path (GET /api/state).
 *
 * Accepts VIEW_PASSWORD (if set) OR PUSH_SECRET — whichever matches.
 * If VIEW_PASSWORD is not configured, only PUSH_SECRET is accepted.
 * Never falls back to any hardcoded string.
 */
export function verifyReadToken(candidate: string | null): boolean {
  if (!candidate) return false;

  const viewPassword = process.env.VIEW_PASSWORD;
  const pushSecret = process.env.PUSH_SECRET;

  // Try VIEW_PASSWORD first (preferred read credential).
  if (viewPassword && timingSafeEqual_str(candidate, viewPassword)) {
    return true;
  }

  // Fall back to PUSH_SECRET so existing curl checks keep working.
  if (pushSecret && timingSafeEqual_str(candidate, pushSecret)) {
    return true;
  }

  return false;
}

/**
 * Convenience: reads the Authorization header from a Request, extracts the
 * bearer token, and verifies it against PUSH_SECRET.
 * Use for POST /api/push only.
 */
export function authorizeRequest(request: Request): boolean {
  const authHeader = request.headers.get("Authorization");
  const token = extractBearerToken(authHeader);
  return verifyToken(token);
}

/**
 * Convenience: reads the Authorization header from a Request, extracts the
 * bearer token, and verifies it for the read path (accepts VIEW_PASSWORD or
 * PUSH_SECRET, but NOT for push).
 * Use for GET /api/state only.
 */
export function authorizeReadRequest(request: Request): boolean {
  const authHeader = request.headers.get("Authorization");
  const token = extractBearerToken(authHeader);
  return verifyReadToken(token);
}
