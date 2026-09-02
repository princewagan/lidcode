/**
 * lib/schema.ts
 *
 * Single source of truth for the Warp Monitor JSON state contract.
 * Field names, types, and schema_version MUST stay in sync with
 * the Swift Models.swift Codable structs in mac-app/.
 *
 * Do NOT rename or add fields without updating both sides.
 */

import { z } from "zod";

// ---------------------------------------------------------------------------
// ClaudeSession
// ---------------------------------------------------------------------------

export const ClaudeSessionSchema = z.object({
  session_id: z.string(),
  project: z.string(),
  last_event: z.enum([
    "session_start",
    "prompt_submit",
    "tool_complete",
    "idle_prompt",
    "stop",
    "stop_failure",
    "permission_request",
  ]),
  last_event_at: z.string().datetime(),
  tool_name: z.string().optional(),
  error_type: z.string().optional(),
  /**
   * The agent name from the OSC 777 event body (e.g. "claude").
   * Optional — omitted by old Mac binary versions; safe to default to undefined.
   */
  agent: z.string().optional(),
  /**
   * Human-readable description of what Claude is asking permission for.
   * Populated from the "summary" field of a permission_request event.
   * Truncated to 200 chars on the Swift side to keep the blob small.
   */
  blocked_reason: z.string().optional(),
  /**
   * The user's original query text at the time of a stop_failure event.
   * Populated from the "query" field of a stop_failure event.
   * Truncated to 200 chars on the Swift side.
   */
  last_query: z.string().optional(),
});

export type ClaudeSession = z.infer<typeof ClaudeSessionSchema>;

// ---------------------------------------------------------------------------
// ClaudeStatus
//
// "warning" is kept for backward compatibility with old Mac binary pushes.
// New binary emits "blocked" (permission_request — Claude waiting on user)
// or "error" (stop_failure — something failed) instead of the generic "warning".
// The phone UI maps all three to a visible amber/orange state.
// ---------------------------------------------------------------------------

export const ClaudeStatusSchema = z.enum([
  "running",
  "finished",
  "blocked",  // permission_request: Claude waiting on user approval
  "error",    // stop_failure: something failed
  "warning",  // legacy: old Mac binary emits this; treat same as "blocked" in UI
  "idle",
]);

export type ClaudeStatus = z.infer<typeof ClaudeStatusSchema>;

// ---------------------------------------------------------------------------
// WarpTab
// ---------------------------------------------------------------------------

export const WarpTabSchema = z.object({
  id: z.string(),
  title: z.string(),
  custom_title: z.string().nullable().default(null),
  cwd: z.string(),
  pinned: z.boolean(),
  claude_status: ClaudeStatusSchema,
  claude_sessions: z.array(ClaudeSessionSchema),
  ambiguous_cwd: z.boolean(),
  /**
   * True when this tab's pane is the currently focused terminal pane.
   * Optional with a false default so pushes from older Mac app versions
   * still validate. In practice the DB stores this as a DEFAULT column so
   * Swift always emits explicit false rather than omitting the key.
   */
  is_focused: z.boolean().optional().default(false),
  /**
   * Current git branch for the tab's working directory.
   * Parsed from <cwd>/.git/HEAD ("ref: refs/heads/<branch>").
   * null when: no .git found, detached HEAD, or cwd is empty.
   * Optional so old Mac binary pushes (without this field) still validate.
   */
  git_branch: z.string().nullable().optional(),
  /**
   * TTY name of the Claude process inferred to be running in this tab.
   * e.g. "ttys005". Absent when no Claude process could be paired with this tab.
   *
   * Pairing is heuristic: tabs and live Claude processes are sorted ascending
   * (tab id asc, TTY number asc) and matched 1:1 within the same cwd. This is
   * not a guarantee — Warp does not expose which pane owns which TTY. The UI
   * uses this field as a disambiguator, not as an authoritative identity.
   *
   * Optional so old Mac binary pushes (without this field) still validate.
   */
  tty: z.string().optional(),
  /**
   * PID of the Claude process inferred to be running in this tab.
   * Absent when no Claude process could be paired with this tab.
   * Optional so old Mac binary pushes (without this field) still validate.
   */
  claude_pid: z.number().int().optional(),
  /**
   * AI-generated session title from the Claude Code transcript file.
   * Extracted from the last `{"type":"ai-title","aiTitle":"..."}` line in
   * ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl.
   * null/absent when no transcript found or no ai-title written yet.
   * Optional so old Mac binary pushes still validate.
   */
  ai_title: z.string().optional(),
  /**
   * Which title derivation rule produced the value in `title` (on the Swift side)
   * or the resolved display title (on the TypeScript side).
   * One of: "ai-title-exact", "ai-title-fallback", "custom-vertical-tab",
   *         "custom-tab", "cwd-basename", "tab-id", "no-ai-title", "no-transcript".
   * Optional so old Mac binary pushes still validate.
   */
  title_source: z.string().optional(),
});

export type WarpTab = z.infer<typeof WarpTabSchema>;

// ---------------------------------------------------------------------------
// WarpTabGroup
// ---------------------------------------------------------------------------

export const WarpTabGroupSchema = z.object({
  id: z.string(),
  name: z.string(),
  color: z.string().nullable().default(null),
  collapsed: z.boolean(),
  tabs: z.array(WarpTabSchema),
});

export type WarpTabGroup = z.infer<typeof WarpTabGroupSchema>;

// ---------------------------------------------------------------------------
// WarpNotification
// ---------------------------------------------------------------------------

export const WarpNotificationSchema = z.object({
  id: z.string(),
  received_at: z.string().datetime(),
  title: z.string(),
  body_raw: z.string(),
  parsed_event: z.string().nullable().default(null),
});

export type WarpNotification = z.infer<typeof WarpNotificationSchema>;

// ---------------------------------------------------------------------------
// WarpMonitorState  (top-level, matches what Mac POSTs to /api/push)
//
// NOTE: orphan_sessions is included here even though the plan's Zod schema
// section omitted it. The CWD Ambiguity Rule section of the plan explicitly
// requires a top-level orphan_sessions array. Adding it here keeps the
// contract complete and prevents a Swift/JS mismatch.
// ---------------------------------------------------------------------------

export const WarpMonitorStateSchema = z.object({
  schema_version: z.literal(1),
  pushed_at: z.string().datetime(),
  mac_hostname: z.string(),
  warp_running: z.boolean(),
  tab_groups: z.array(WarpTabGroupSchema),
  ungrouped_tabs: z.array(WarpTabSchema),
  notifications: z.array(WarpNotificationSchema).max(50),
  orphan_sessions: z.array(ClaudeSessionSchema).optional(),
  /** Set when the SQLite reader fails. Phone shows "Mac reader error". */
  mac_reader_error: z.string().optional(),
});

export type WarpMonitorState = z.infer<typeof WarpMonitorStateSchema>;
