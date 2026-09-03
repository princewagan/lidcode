/**
 * app/demoState.ts
 *
 * Demo fixtures for /?demo=1 (v2 shape) and /?demo=v1 (v1 backward-compat).
 *
 * WHY THIS EXISTS
 * ---------------
 * The real page reads from Postgres via GET /api/lidcode. Before the Mac app has
 * ever pushed (or before the table exists) there is nothing to look at, which
 * makes design iteration impossible and makes the page look broken to a first
 * time visitor. These fixtures render representative frames that exercise every
 * visual state the page can be in.
 *
 * IT IS NEVER THE DEFAULT. The dashboard only uses fixtures when the URL carries
 * `?demo=1` (full v2 shape) or `?demo=v1` (v1 shape, proves backward compat).
 * Both modes show a visible DEMO marker in the header. No network call is made
 * and no token is required in either demo mode.
 *
 * Timestamps are generated relative to "now" so the relative-time column always
 * reads naturally ("just now" / "10m ago" / "2h ago" / "yesterday").
 */

import type {
  LidCodeState,
  LidCodeSession,
  LidCodeMemory,
  LidCodeClaudeAccount,
} from "@/lib/lidcodeSchema";

/** Query flag name. */
export const DEMO_QUERY_FLAG = "demo";

/**
 * Returns the demo variant requested by the URL, or null if not in demo mode.
 *
 *   /?demo=1   → "v2"  (full schema_version 3 fixture — memory, accounts, status)
 *   /?demo=v1  → "v1"  (schema_version 1 fixture, no memory/claude_accounts)
 *   anything else → null
 */
export function getDemoVariant(search: string): "v1" | "v2" | null {
  const value = new URLSearchParams(search).get(DEMO_QUERY_FLAG);
  if (value === "1") return "v2";
  if (value === "v1") return "v1";
  return null;
}

/** True only for `?demo=1` or `?demo=v1`. */
export function isDemoRequested(search: string): boolean {
  return getDemoVariant(search) !== null;
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

function ago(now: number, ms: number): string {
  return new Date(now - ms).toISOString();
}

// ---------------------------------------------------------------------------
// Shared sessions fixture — identical for both demo variants
// ---------------------------------------------------------------------------

function buildSessions(t: number): LidCodeSession[] {
  return [
    {
      id: "s-running-1",
      agent: "claude",
      project: "lidcode",
      title: "Port WarpMonitor session detection into LidCode",
      status: "running",
      status_changed_at: ago(t, 2_000), // just now
      last_seen_at: ago(t, 1_000),
      cwd: "/Users/prince/lidcode",
    },
    {
      id: "s-running-2",
      agent: "codex",
      project: "north-star",
      title: "Create test admin and staff accounts",
      status: "running",
      status_changed_at: ago(t, 10 * MINUTE), // 10m ago
      last_seen_at: ago(t, 30_000),
      cwd: "/Users/prince/north-star",
    },
    {
      id: "s-blocked-1",
      agent: "claude",
      project: "lidcode",
      title: "Fix the menu bar freeze after wake",
      status: "blocked",
      status_changed_at: ago(t, 4 * MINUTE), // 4m ago
      last_seen_at: ago(t, 20_000),
      cwd: "/Users/prince/lidcode/mac-app",
    },
    {
      id: "s-error-1",
      agent: "claude",
      project: "television",
      title: "Migrate the push endpoint off the legacy storage helper",
      status: "error",
      status_changed_at: ago(t, 2 * HOUR), // 2h ago
      last_seen_at: ago(t, 2 * HOUR),
      cwd: "/Users/prince/television",
    },
    {
      id: "s-finished-1",
      agent: "codex",
      project: "north-star",
      title: "Rewrite the onboarding copy for the staff invite email",
      status: "finished",
      status_changed_at: ago(t, 3 * HOUR), // 3h ago
      last_seen_at: ago(t, 3 * HOUR),
      cwd: "/Users/prince/north-star",
    },
    {
      id: "s-finished-2",
      agent: "claude",
      project: "television",
      title: "Add Postgres table for the LidCode state blob",
      status: "finished",
      status_changed_at: ago(t, 26 * HOUR), // yesterday
      last_seen_at: ago(t, 26 * HOUR),
      cwd: "/Users/prince/television",
    },
    {
      id: "s-finished-3",
      agent: "claude",
      project: "lidcode",
      title: "Stop the hold timer from resetting on every poll",
      status: "finished",
      status_changed_at: ago(t, 3 * 24 * HOUR), // 3d ago
      last_seen_at: ago(t, 3 * 24 * HOUR),
      cwd: "/Users/prince/lidcode",
    },
  ];
}

// ---------------------------------------------------------------------------
// v2 memory fixture
// ---------------------------------------------------------------------------

const DEMO_MEMORY: LidCodeMemory = {
  pressure: "warn",
  used_percent: 78.3,
  swap_used_mb: 998.6,
  swap_total_mb: 2048.0,
  app: [
    { name: "Claude", mb: 6297.0, count: 11 },
    { name: "Xcode", mb: 4102.5, count: 3 },
    { name: "Safari", mb: 1843.2, count: 12 },
    { name: "Slack", mb: 892.1, count: 2 },
    { name: "Figma", mb: 744.8, count: 1 },
    { name: "Terminal", mb: 321.0, count: 6 },
  ],
};

// ---------------------------------------------------------------------------
// v2 claude_accounts fixture — two accounts, one active
// ---------------------------------------------------------------------------

const DEMO_CLAUDE_ACCOUNTS: LidCodeClaudeAccount[] = [
  {
    key: "prince",
    five_hour_utilization: 14.0,
    seven_day_utilization: 7.0,
    is_active: true,
    status: "ok",
  },
  {
    key: "work",
    five_hour_utilization: 9.0,
    seven_day_utilization: 12.0,
    is_active: false,
    status: "ok",
  },
];

// ---------------------------------------------------------------------------
// createDemoState — full v2 fixture (used by ?demo=1)
//
// One representative frame:
//   - awake held with the lid physically closed (the whole point of LidCode)
//   - hold timer 42% elapsed, ~1h 26m left
//   - battery 83% on battery, 61.0 °C and fresh
//   - Claude 5-hour 14%, 7-day 7%
//   - 3 other apps also blocking sleep
//   - 7 sessions: 2 running, 1 blocked, 1 error, 3 finished
//   - memory: warn pressure, 78% used, 6 app rows including Claude
//   - claude_accounts: 2 accounts (prince active, work inactive)
// ---------------------------------------------------------------------------

export function createDemoState(now: Date = new Date()): LidCodeState {
  const t = now.getTime();

  // Hold is 42% elapsed with 1h 26m still to run. The extra 30s stops the
  // floor() in formatTimeLeft from rendering "1h 25m" a moment after mount.
  const holdRemainingMs = 86 * MINUTE + 30_000;

  return {
    schema_version: 3,
    pushed_at: ago(t, 12_000),
    mac_hostname: "prince-mbp",
    awake_held: true,
    physical_lid: "closed",
    status_kind: "holding",
    status_title: "Keeping awake · 2 active sessions",
    status_detail: "Held by claude, codex",
    hold_expires_at: new Date(t + holdRemainingMs).toISOString(),
    hold_elapsed_fraction: 0.42,
    battery_percent: 83,
    battery_on_main: false,
    temperature_celsius: 61,
    temperature_stale: false,
    claude_five_hour_utilization: 14,
    claude_seven_day_utilization: 7,
    foreign_blocker_count: 3,
    sessions: buildSessions(t),
    memory: DEMO_MEMORY,
    claude_accounts: DEMO_CLAUDE_ACCOUNTS,
  };
}

// ---------------------------------------------------------------------------
// createDemoStateV1 — v1 fixture (used by ?demo=v1)
//
// Identical to v2 but omits memory and claude_accounts entirely.
// Proves that the UI renders cleanly with v1 payloads — backward compatibility
// is exercised in a real render, not merely assumed.
// ---------------------------------------------------------------------------

export function createDemoStateV1(now: Date = new Date()): LidCodeState {
  const t = now.getTime();
  const holdRemainingMs = 86 * MINUTE + 30_000;

  return {
    schema_version: 1,
    pushed_at: ago(t, 12_000),
    mac_hostname: "prince-mbp-v1",
    awake_held: true,
    physical_lid: "closed",
    hold_expires_at: new Date(t + holdRemainingMs).toISOString(),
    hold_elapsed_fraction: 0.42,
    battery_percent: 83,
    battery_on_main: false,
    temperature_celsius: 61,
    temperature_stale: false,
    claude_five_hour_utilization: 14,
    claude_seven_day_utilization: 7,
    foreign_blocker_count: 3,
    sessions: buildSessions(t),
    // memory and claude_accounts intentionally absent — this is a v1 payload
  };
}
