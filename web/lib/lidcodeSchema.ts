/**
 * lib/lidcodeSchema.ts
 *
 * Zod schema for the LidCode push payload.
 *
 * Mirrors LidCodePushPayload and LidCodeSessionPayload from the Frozen Contract
 * in the plan. Field names are snake_case to match the Swift Codable structs.
 *
 * Schema versions:
 *   v1 — original fields only
 *   v2 — adds optional `memory` and `claude_accounts` top-level fields
 *
 * Both optional fields are .optional() so a Mac still on v1 never gets 400'd.
 *
 * Do NOT import or re-export from lib/schema.ts — these are separate contracts.
 */

import { z } from "zod";

// ---------------------------------------------------------------------------
// LidCodeSession — one entry in the sessions array
// ---------------------------------------------------------------------------

export const LidCodeSessionSchema = z.object({
  id: z.string(),
  agent: z.string(),
  project: z.string(),
  title: z.string(),
  status: z.enum(["running", "blocked", "error", "finished"]),
  status_changed_at: z.string().datetime(),
  last_seen_at: z.string().datetime(),
  cwd: z.string(),
});

export type LidCodeSession = z.infer<typeof LidCodeSessionSchema>;

// ---------------------------------------------------------------------------
// Memory — optional, schema_version 2+
// ---------------------------------------------------------------------------

export const LidCodeMemoryAppSchema = z.object({
  name: z.string(),
  mb: z.number(),
  count: z.number().int().optional(),
});

export type LidCodeMemoryApp = z.infer<typeof LidCodeMemoryAppSchema>;

export const LidCodeMemorySchema = z.object({
  pressure: z.enum(["normal", "warn", "critical"]),
  used_percent: z.number().min(0).max(100),
  swap_used_mb: z.number().min(0),
  swap_total_mb: z.number().min(0),
  app: z.array(LidCodeMemoryAppSchema).optional(),
});

export type LidCodeMemory = z.infer<typeof LidCodeMemorySchema>;

// ---------------------------------------------------------------------------
// ClaudeAccount — one entry in claude_accounts, optional, schema_version 2+
// ---------------------------------------------------------------------------

export const LidCodeClaudeAccountSchema = z.object({
  key: z.string(),
  five_hour_utilization: z.number().min(0).max(100),
  seven_day_utilization: z.number().min(0).max(100),
  is_active: z.boolean(),
  status: z.string(), // "ok" | "signed_out" | "expired" | others
});

export type LidCodeClaudeAccount = z.infer<typeof LidCodeClaudeAccountSchema>;

// ---------------------------------------------------------------------------
// LidCodeState — top-level payload, matches what LidCode.app POSTs
// ---------------------------------------------------------------------------

export const LidCodeStateSchema = z.object({
  schema_version: z.union([z.literal(1), z.literal(2)]),
  pushed_at: z.string().datetime(),
  mac_hostname: z.string(),
  awake_held: z.boolean(),
  physical_lid: z.enum(["open", "closed", "unknown"]),
  hold_expires_at: z.string().datetime().optional(),
  hold_elapsed_fraction: z.number().min(0).max(1).optional(),
  battery_percent: z.number().int().min(0).max(100).optional(),
  battery_on_main: z.boolean(),
  temperature_celsius: z.number().optional(),
  temperature_stale: z.boolean(),
  claude_five_hour_utilization: z.number().min(0).max(100).optional(),
  claude_seven_day_utilization: z.number().min(0).max(100).optional(),
  foreign_blocker_count: z.number().int().min(0),
  sessions: z.array(LidCodeSessionSchema),
  // v2 optional fields — absent on v1 pushes, never required
  memory: LidCodeMemorySchema.optional(),
  claude_accounts: z.array(LidCodeClaudeAccountSchema).optional(),
});

export type LidCodeState = z.infer<typeof LidCodeStateSchema>;
