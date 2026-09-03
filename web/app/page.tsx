"use client";

/**
 * app/page.tsx
 *
 * LidCode phone dashboard — / (site root)
 *
 * DESIGN
 * ------
 * Pure #000. White type. Thin white lines as the only structural device — no
 * cards, no radii, no gradients, no shadows, no emoji. Helvetica Neue Light at
 * hard negative tracking (-0.062em on the hero word, -0.05em on metric numbers,
 * -0.022em on body) played against 10px uppercase micro-labels at +0.16em.
 * That size/tracking contrast is the whole aesthetic: film title card, not a
 * settings screen.
 *
 * Colour appears in exactly one place — the 5px status dot on a session group
 * heading. Battery and thermal warnings use a small dot next to the label, never
 * a coloured number, so a hot Mac never turns the page orange.
 *
 * Shared tokens, the reveal animation and the two-line clamp live in
 * `app/globals.css` under `.lc-scope` (see `app/layout.tsx`).
 *
 * Mobile-first, drawn for a 390pt iPhone viewport.
 * Auth: localStorage `lc_token` (separate from wm_token to avoid collision).
 * Polling: GET /api/lidcode every 60s, paused while the tab is hidden.
 *          An immediate refresh fires when the tab becomes visible again.
 *          ETag-aware: sends If-None-Match and keeps prior data on 304.
 * Demo:   /?demo=1 renders v2 fixture (memory + claude_accounts).
 *          /?demo=v1 renders v1 fixture (no memory/accounts) for backward-compat proof.
 */

import { useState, useEffect, useCallback, useRef } from "react";
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
} from "@tanstack/react-query";
import type {
  LidCodeState,
  LidCodeSession,
  LidCodeMemory,
  LidCodeClaudeAccount,
  LidCodeStatusKind,
} from "@/lib/lidcodeSchema";
import {
  createDemoState,
  createDemoStateV1,
  getDemoVariant,
} from "@/app/demoState";

// ---------------------------------------------------------------------------
// QueryClient
// ---------------------------------------------------------------------------

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: 2, refetchOnWindowFocus: true },
  },
});

// ---------------------------------------------------------------------------
// Token helpers — key separate from wm_token so warp and lidcode don't share
// ---------------------------------------------------------------------------

const TOKEN_KEY = "lc_token";

function getStoredToken(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem(TOKEN_KEY);
}
function saveToken(t: string) {
  localStorage.setItem(TOKEN_KEY, t);
}
function clearToken() {
  localStorage.removeItem(TOKEN_KEY);
}

// ---------------------------------------------------------------------------
// Time formatting
// ---------------------------------------------------------------------------

/**
 * Relative time, phone-sized. Deliberately says "yesterday" rather than "1d
 * ago" — it is the one case where a word reads faster than a number.
 */
function relativeTime(iso: string, now: Date = new Date()): string {
  const s = Math.floor((now.getTime() - new Date(iso).getTime()) / 1000);
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  const days = Math.floor(s / 86400);
  if (days === 1) return "yesterday";
  if (days < 7) return `${days}d ago`;
  const weeks = Math.floor(days / 7);
  return weeks === 1 ? "last week" : `${weeks}w ago`;
}

function formatTimeLeft(expiresAt: string, now: Date = new Date()): string {
  const ms = new Date(expiresAt).getTime() - now.getTime();
  if (ms <= 0) return "expired";
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  if (h > 0) return `${h}h ${m}m left`;
  if (m > 0) return `${m}m left`;
  return `${totalSec}s left`;
}

// ---------------------------------------------------------------------------
// Status vocabulary
// ---------------------------------------------------------------------------

/** The page's only colour. Kept to a 5px dot per group heading. */
const STATUS_COLORS: Record<LidCodeSession["status"], string> = {
  running: "#4b8dff",
  blocked: "#e0b437",
  error: "#ff4d4d",
  finished: "rgba(255,255,255,0.30)",
};

const STATUS_ORDER: LidCodeSession["status"][] = [
  "running",
  "blocked",
  "error",
  "finished",
];

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/** Primary 1px structural hairline. `bleed` runs it to the screen edge. */
function Rule({
  bleed = false,
  soft = false,
  style,
}: {
  bleed?: boolean;
  soft?: boolean;
  style?: React.CSSProperties;
}) {
  return (
    <div
      className={bleed ? "lc-bleed" : undefined}
      style={{
        height: 1,
        background: soft ? "var(--lc-line-soft)" : "var(--lc-line)",
        flexShrink: 0,
        ...style,
      }}
    />
  );
}

/** 10px uppercase micro-label, wide tracking. */
function Micro({
  children,
  color,
  style,
}: {
  children: React.ReactNode;
  color?: string;
  style?: React.CSSProperties;
}) {
  return (
    <span data-lc-micro style={{ color, ...style }}>
      {children}
    </span>
  );
}

/**
 * Progress hairline. 2px for the hero hold timer, 1px for the metric meters —
 * the only weight difference on the page, and it is the hierarchy signal.
 */
function Meter({
  fraction,
  thick = false,
}: {
  fraction: number;
  thick?: boolean;
}) {
  const clamped = Math.max(0, Math.min(1, fraction));
  return (
    <div
      style={{
        height: thick ? 2 : 1,
        background: "var(--lc-line)",
        position: "relative",
        overflow: "hidden",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: 0,
          right: "auto",
          width: `${clamped * 100}%`,
          background: "#fff",
          transition: "width 600ms cubic-bezier(0.16,0.84,0.44,1)",
        }}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Accent colour helper — mirrors Palette.usageColor from the Mac app.
// ---------------------------------------------------------------------------

/**
 * Returns one of three CSS colour strings depending on utilisation percentage,
 * matching the Mac app's Palette.usageColor logic:
 *   >=90 % → deeper accent (hotter orange)
 *   >=70 % → normal accent (#D97757)
 *   <70 %  → muted grey (matches brandSoft)
 */
function usageColor(percent: number): string {
  if (percent >= 90) return "var(--lc-accent-deep)";
  if (percent >= 70) return "var(--lc-accent)";
  return "var(--lc-accent-soft)";
}

// ---------------------------------------------------------------------------
// BarGauge — single labelled progress bar matching the Mac app BarGauge style.
// Label left, monospaced-digit value right, 6px tall filled bar.
// ---------------------------------------------------------------------------

/**
 * BarGauge renders the same structure as the Swift BarGauge in LidCodeApp:
 *   [LABEL]               [VALUE]
 *   ████████░░░░░░░░░░░░░░░
 *
 * `color` should be a CSS colour string — the bar fill uses it directly.
 * `soft` renders the track at a lower opacity so memory bars read differently
 * from usage bars without adding another component.
 */
function BarGauge({
  label,
  fraction,
  color,
  value,
}: {
  label: string;
  fraction: number;
  color: string;
  value: string;
}) {
  const clamped = Math.max(0, Math.min(1, fraction));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 5 }}>
      {/* Label row */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
          gap: 8,
        }}
      >
        <Micro style={{ color: "var(--lc-fg-3)" }}>{label}</Micro>
        <span
          className="lc-mono"
          style={{
            fontSize: 10,
            fontWeight: 500,
            letterSpacing: "0.04em",
            color: "var(--lc-fg-2)",
            textTransform: "uppercase",
            flexShrink: 0,
          }}
        >
          {value}
        </span>
      </div>
      {/* Track + fill — 6px tall matching the Mac app's 6pt bar */}
      <div
        style={{
          height: 6,
          background: "var(--lc-line)",
          position: "relative",
          overflow: "hidden",
        }}
      >
        <div
          style={{
            position: "absolute",
            inset: 0,
            right: "auto",
            width: `${clamped * 100}%`,
            background: color,
            transition: "width 600ms cubic-bezier(0.16,0.84,0.44,1)",
          }}
        />
      </div>
    </div>
  );
}

/**
 * Section wrapper: full-bleed rule across the top, then the content, revealed
 * on a stagger. `style` lands on the content box so section padding never
 * pushes the rule off the join.
 */
function Band({
  children,
  index = 0,
  rule = true,
  style,
}: {
  children: React.ReactNode;
  index?: number;
  rule?: boolean;
  style?: React.CSSProperties;
}) {
  return (
    <section className="lc-rise" style={{ animationDelay: `${index * 70}ms` }}>
      {rule && <Rule bleed />}
      <div style={style}>{children}</div>
    </section>
  );
}

/**
 * SectionLabel — uppercase section header with optional trailing note.
 * Matches the Mac app's `SectionLabel` component.
 */
function SectionLabel({
  text,
  trailing,
}: {
  text: string;
  trailing?: string | null;
}) {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        alignItems: "baseline",
        gap: 8,
        marginBottom: 2,
      }}
    >
      <Micro style={{ color: "var(--lc-fg-2)", letterSpacing: "0.22em" }}>
        {text}
      </Micro>
      {trailing && (
        <Micro style={{ color: "var(--lc-fg-4)", letterSpacing: "0.1em" }}>
          {trailing}
        </Micro>
      )}
    </div>
  );
}

/**
 * 44x44 minimum touch target. The label inside is 10px, so the box has to be
 * declared rather than inherited from the text.
 */
const TAP_TARGET: React.CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "flex-end",
  minHeight: 44,
  minWidth: 44,
  paddingLeft: 14,
  color: "var(--lc-fg-4)",
  textDecoration: "none",
  WebkitTapHighlightColor: "transparent",
};

// ---------------------------------------------------------------------------
// Top rail — wordmark + liveness
// ---------------------------------------------------------------------------

function TopRail({
  isFetching,
  updatedAt,
  demo,
  onSignOut,
}: {
  isFetching: boolean;
  updatedAt: string | null;
  demo: boolean;
  onSignOut?: () => void;
}) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        minHeight: 44,
        gap: 12,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
        <Micro style={{ color: "var(--lc-fg-2)", letterSpacing: "0.22em" }}>
          LidCode
        </Micro>
        {demo && (
          <Micro
            style={{
              color: "var(--lc-fg-3)",
              border: "1px solid var(--lc-line)",
              padding: "3px 6px 2px",
              letterSpacing: "0.18em",
            }}
          >
            Demo
          </Micro>
        )}
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span
          aria-hidden
          style={{
            width: 4,
            height: 4,
            borderRadius: "50%",
            background: isFetching ? STATUS_COLORS.running : "var(--lc-fg-4)",
            flexShrink: 0,
            transition: "background 300ms",
          }}
        />
        <Micro style={{ color: "var(--lc-fg-3)" }}>
          {isFetching
            ? "Syncing"
            : updatedAt
            ? relativeTime(updatedAt)
            : "Live"}
        </Micro>
        {demo ? (
          <a href="/" style={TAP_TARGET}>
            <Micro style={{ color: "var(--lc-fg-3)" }}>Exit</Micro>
          </a>
        ) : (
          onSignOut && (
            <button
              type="button"
              onClick={() => {
                clearToken();
                onSignOut();
              }}
              style={{
                ...TAP_TARGET,
                background: "none",
                border: "none",
                cursor: "pointer",
                font: "inherit",
              }}
            >
              <Micro style={{ color: "var(--lc-fg-3)" }}>Sign out</Micro>
            </button>
          )
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Hero — the title card
// ---------------------------------------------------------------------------

/**
 * Trouble states get the error dot next to the headline. A Mac that stopped
 * ticking or is refusing to re-arm looks identical to a healthy idle one if you
 * only read `awake_held`, and the phone is where you look precisely because you
 * cannot see the menu bar.
 */
function statusIsTrouble(kind: LidCodeStatusKind | undefined): boolean {
  return kind === "stalled" || kind === "blocked";
}

function Hero({ state }: { state: LidCodeState }) {
  const now = new Date();
  const running = state.sessions.filter((s) => s.status === "running").length;

  const lidLabel =
    state.physical_lid === "closed"
      ? "Lid closed"
      : state.physical_lid === "open"
      ? "Lid open"
      : "Lid unknown";

  // v3 sends the exact line the menu bar shows. Older Macs don't, so keep
  // deriving something reasonable from the fields v1 always had.
  const subtitle =
    state.status_title ??
    (state.awake_held
      ? running > 0
        ? `Held awake · ${running} session${running === 1 ? "" : "s"}`
        : "Held awake"
      : running > 0
      ? "Sleep not held · sessions running"
      : "Free to sleep");

  const trouble = statusIsTrouble(state.status_kind);

  return (
    <Band index={0} style={{ paddingTop: 32, paddingBottom: 32 }}>
      <div style={{ display: "flex", gap: 9, alignItems: "baseline" }}>
        <Micro>{state.mac_hostname}</Micro>
        <Micro style={{ color: "var(--lc-fg-4)" }}>/</Micro>
        <Micro>{lidLabel}</Micro>
      </div>

      <h1
        data-lc-display="hero"
        style={{
          /* Fluid so the longest word ("ASLEEP") can never overflow: ~83px in a
             280px column at 320 wide, ~101px in 350 at 390 wide, capped at
             104px so it stops growing on tablet/desktop. */
          fontSize: "clamp(64px, 26vw, 104px)",
          margin: "20px 0 0",
          color: "var(--lc-fg)",
        }}
      >
        {state.awake_held ? "AWAKE" : "ASLEEP"}
      </h1>

      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          margin: "16px 0 0",
        }}
      >
        {trouble && (
          <span
            aria-hidden
            style={{
              width: 6,
              height: 6,
              borderRadius: "50%",
              background: STATUS_COLORS.error,
              flexShrink: 0,
            }}
          />
        )}
        <p
          style={{
            margin: 0,
            fontSize: 14,
            letterSpacing: "-0.035em",
            color: trouble ? "var(--lc-fg)" : "var(--lc-fg-2)",
          }}
        >
          {subtitle}
        </p>
      </div>

      {/* The sentence behind the headline — "Held by claude, codex", or why a
          guard is refusing to re-arm. v3 only. */}
      {state.status_detail && (
        <p style={{ margin: "8px 0 0" }}>
          <Micro style={{ color: "var(--lc-fg-3)" }}>{state.status_detail}</Micro>
        </p>
      )}

      {/* Hold timer — the one 2px line on the page. */}
      {state.hold_expires_at != null && (
        <div style={{ marginTop: 28 }}>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              marginBottom: 10,
              gap: 12,
            }}
          >
            <Micro>
              Hold
              {state.hold_elapsed_fraction != null
                ? ` ${Math.round(state.hold_elapsed_fraction * 100)}%`
                : ""}
            </Micro>
            <Micro style={{ color: "var(--lc-fg-2)" }}>
              {formatTimeLeft(state.hold_expires_at, now)}
            </Micro>
          </div>
          <Meter fraction={state.hold_elapsed_fraction ?? 0} thick />
        </div>
      )}

      {state.foreign_blocker_count > 0 && (
        <p style={{ margin: "14px 0 0" }}>
          <Micro>
            {state.foreign_blocker_count} other app
            {state.foreign_blocker_count === 1 ? "" : "s"} blocking sleep
          </Micro>
        </p>
      )}
    </Band>
  );
}

// ---------------------------------------------------------------------------
// Metrics quadrant — 2×2, divided by thin white lines
// ---------------------------------------------------------------------------

function Cell({
  label,
  warn = false,
  value,
  unit,
  meter,
  borderRight,
  borderBottom,
}: {
  label: string;
  warn?: boolean;
  value: string;
  unit?: string;
  meter: number | null;
  borderRight: boolean;
  borderBottom: boolean;
}) {
  return (
    <div
      style={{
        paddingTop: borderBottom ? 22 : 22,
        paddingBottom: 22,
        paddingRight: borderRight ? 18 : 0,
        paddingLeft: borderRight ? 0 : 18,
        borderRight: borderRight ? "1px solid var(--lc-line)" : undefined,
        borderBottom: borderBottom ? "1px solid var(--lc-line)" : undefined,
        minWidth: 0,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        {/* Warning is a 4px dot, never a coloured number. */}
        {warn && (
          <span
            aria-hidden
            style={{
              width: 4,
              height: 4,
              borderRadius: "50%",
              background: STATUS_COLORS.error,
              flexShrink: 0,
            }}
          />
        )}
        <Micro>{label}</Micro>
      </div>

      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          marginTop: 12,
          marginBottom: 14,
        }}
      >
        <span
          data-lc-display="metric"
          style={{ fontSize: 40, color: "var(--lc-fg)" }}
        >
          {value}
        </span>
        {unit && (
          <span
            style={{
              fontSize: 15,
              letterSpacing: "-0.03em",
              color: "var(--lc-fg-3)",
              /* Optically kerned into the digit — "1" and "7" carry a wide
                 right sidebearing that otherwise opens a gap. */
              marginLeft: value.endsWith("1") || value.endsWith("7") ? -3 : 0,
            }}
          >
            {unit}
          </span>
        )}
      </div>

      {meter != null ? <Meter fraction={meter} /> : <div style={{ height: 1 }} />}
    </div>
  );
}

function MetricsGrid({ state }: { state: LidCodeState }) {
  const battery = state.battery_percent;
  const temp = state.temperature_celsius;

  return (
    <Band index={1}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
        }}
      >
        <Cell
          label={state.battery_on_main ? "Battery · AC" : "Battery"}
          warn={battery != null && battery < 20 && !state.battery_on_main}
          value={battery != null ? String(battery) : "--"}
          unit="%"
          meter={battery != null ? battery / 100 : null}
          borderRight
          borderBottom={false}
        />
        <Cell
          label={state.temperature_stale ? "Temp · stale" : "Temp"}
          warn={temp != null && temp > 85}
          value={temp != null ? String(Math.round(temp)) : "--"}
          unit="°C"
          /* 0–100 °C maps to the full hairline; ~100 °C is the thermal ceiling. */
          meter={temp != null ? temp / 100 : null}
          borderRight={false}
          borderBottom={false}
        />
      </div>
    </Band>
  );
}

// ---------------------------------------------------------------------------
// Claude accounts band
//
// Replaces the two Claude cells that were in the 2x2 grid. Lists every account
// from `claude_accounts` with a 5-hour bar and a 1-week bar, marking the active
// account. Falls back to the v1 aggregate fields when `claude_accounts` is absent.
// ---------------------------------------------------------------------------

/**
 * One account block — label row + 5-hour bar + 1-week bar.
 * Matches the Swift `usageBlock` function in MenuView.
 */
function ClaudeAccountBlock({
  label,
  trailing,
  fiveHourPct,
  sevenDayPct,
  isActive,
  accountStatus,
}: {
  label: string;
  trailing?: string | null;
  fiveHourPct: number | null;
  sevenDayPct: number | null;
  isActive: boolean;
  accountStatus: string;
}) {
  const isOk = accountStatus === "ok";
  const statusPhrase = isOk
    ? null
    : accountStatus === "signed_out"
    ? "signed out"
    : accountStatus === "expired"
    ? "needs login"
    : "error";

  const trailingWithActive = (() => {
    const base = isOk ? trailing : statusPhrase;
    if (!isActive) return base ?? null;
    if (base) return `${base} · active`;
    return "active";
  })();

  // Bar colour: accent, degraded to soft when not ok.
  const barColor = (pct: number | null) => {
    if (!isOk || pct == null) return "var(--lc-line)";
    return usageColor(pct);
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <SectionLabel text={label} trailing={trailingWithActive} />
      <BarGauge
        label="5 Hour"
        fraction={isOk && fiveHourPct != null ? fiveHourPct / 100 : 0}
        color={barColor(fiveHourPct)}
        value={isOk && fiveHourPct != null ? `${Math.round(fiveHourPct)}%` : "—"}
      />
      <BarGauge
        label="1 Week"
        fraction={isOk && sevenDayPct != null ? sevenDayPct / 100 : 0}
        color={barColor(sevenDayPct)}
        value={isOk && sevenDayPct != null ? `${Math.round(sevenDayPct)}%` : "—"}
      />
    </div>
  );
}

/**
 * ClaudeAccountsBand renders per-account usage rows when `claude_accounts` is
 * present (schema_version 2), and falls back to the aggregate v1 fields so a
 * Mac still on v1 still sees Claude usage.
 */
function ClaudeAccountsBand({
  state,
  index,
}: {
  state: LidCodeState;
  index: number;
}) {
  const accounts: LidCodeClaudeAccount[] | undefined = state.claude_accounts;
  const hasFallback =
    state.claude_five_hour_utilization != null ||
    state.claude_seven_day_utilization != null;

  // Nothing to show at all — skip the band (shouldn't happen with real data).
  if (!accounts && !hasFallback) return null;

  return (
    <Band
      index={index}
      style={{
        paddingTop: 20,
        paddingBottom: 20,
        display: "flex",
        flexDirection: "column",
        gap: 20,
      }}
    >
      {accounts && accounts.length > 0 ? (
        // v2 path: one block per account
        accounts.map((acct) => (
          <ClaudeAccountBlock
            key={acct.key}
            label={acct.key}
            fiveHourPct={acct.five_hour_utilization}
            sevenDayPct={acct.seven_day_utilization}
            isActive={acct.is_active}
            accountStatus={acct.status}
          />
        ))
      ) : (
        // v1 fallback: single aggregate block
        <ClaudeAccountBlock
          label="Claude"
          fiveHourPct={state.claude_five_hour_utilization ?? null}
          sevenDayPct={state.claude_seven_day_utilization ?? null}
          isActive={false}
          accountStatus="ok"
        />
      )}
    </Band>
  );
}

// ---------------------------------------------------------------------------
// Memory band — schema_version 2 only, hidden when `memory` is absent.
// Shows overall used %, swap used, pressure state, and per-app list.
// ---------------------------------------------------------------------------

/** How many per-app rows the phone shows before it stops listing. */
const MEMORY_ROW_LIMIT = 12;

function pressureColor(pressure: LidCodeMemory["pressure"]): string {
  if (pressure === "critical") return "var(--lc-error)";
  if (pressure === "warn") return "var(--lc-blocked)";
  return "var(--lc-fg-4)"; // normal — dim, not alarming
}

function formatMb(mb: number): string {
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${Math.round(mb)} MB`;
}

function MemoryBand({
  memory,
  index,
}: {
  memory: LidCodeMemory;
  index: number;
}) {
  const swapFraction =
    memory.swap_total_mb > 0
      ? Math.min(1, memory.swap_used_mb / memory.swap_total_mb)
      : 0;

  // The Mac pushes every process it saw — hundreds of them. Only the heavy end
  // is worth a phone screen, so mirror the menu and show the top consumers with
  // a count of what was left off.
  const allApps = memory.app ?? [];
  const rows = [...allApps].sort((a, b) => b.mb - a.mb).slice(0, MEMORY_ROW_LIMIT);
  const hiddenAppCount = allApps.length - rows.length;

  return (
    <Band
      index={index}
      style={{
        paddingTop: 20,
        paddingBottom: 20,
        display: "flex",
        flexDirection: "column",
        gap: 8,
      }}
    >
      {/* Section header + pressure state */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
          marginBottom: 4,
        }}
      >
        <Micro style={{ color: "var(--lc-fg-2)", letterSpacing: "0.22em" }}>
          Memory
        </Micro>
        <Micro
          style={{
            color: pressureColor(memory.pressure),
            letterSpacing: "0.12em",
          }}
        >
          {memory.pressure}
        </Micro>
      </div>

      {/* Overall used bar */}
      <BarGauge
        label="Used"
        fraction={memory.used_percent / 100}
        color={
          memory.pressure === "critical"
            ? "var(--lc-error)"
            : memory.pressure === "warn"
            ? "var(--lc-blocked)"
            : "var(--lc-accent)"
        }
        value={`${memory.used_percent.toFixed(1)}%`}
      />

      {/* Swap bar — only when swap is configured */}
      {memory.swap_total_mb > 0 && (
        <BarGauge
          label="Swap"
          fraction={swapFraction}
          color={swapFraction > 0.7 ? "var(--lc-blocked)" : "var(--lc-accent-soft)"}
          value={`${formatMb(memory.swap_used_mb)} / ${formatMb(memory.swap_total_mb)}`}
        />
      )}

      {/* Per-app list — heaviest first, trimmed to the top consumers */}
      {rows.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <Rule soft style={{ marginBottom: 10 }} />
          {rows.map((app, i) => (
            <div
              key={app.name}
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "baseline",
                minHeight: 28,
                borderBottom:
                  i < rows.length - 1
                    ? "1px solid var(--lc-line-soft)"
                    : undefined,
                paddingTop: 4,
                paddingBottom: 4,
              }}
            >
              <Micro style={{ color: "var(--lc-fg-2)" }}>
                {app.name}
                {app.count != null && app.count > 1 && (
                  <span style={{ color: "var(--lc-fg-4)", marginLeft: 4 }}>
                    ×{app.count}
                  </span>
                )}
              </Micro>
              <span
                className="lc-mono"
                style={{
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.04em",
                  textTransform: "uppercase",
                  color: "var(--lc-fg-2)",
                }}
              >
                {formatMb(app.mb)}
              </span>
            </div>
          ))}
          {hiddenAppCount > 0 && (
            <p style={{ margin: "10px 0 0" }}>
              <Micro style={{ color: "var(--lc-fg-4)" }}>
                +{hiddenAppCount} smaller
              </Micro>
            </p>
          )}
        </div>
      )}

      {/* Caveat */}
      <p
        style={{
          margin: "8px 0 0",
          fontSize: 9,
          lineHeight: 1.4,
          letterSpacing: "0.04em",
          textTransform: "uppercase",
          color: "var(--lc-fg-4)",
        }}
      >
        Per-process RSS — shared pages counted multiple times. Use for
        relative comparison only.
      </p>
    </Band>
  );
}

// ---------------------------------------------------------------------------
// Sessions — editorial index
// ---------------------------------------------------------------------------

/** Chapter heading: dot, label, hairline running to the edge, count. */
function GroupHeading({
  status,
  count,
}: {
  status: LidCodeSession["status"];
  count: number;
}) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        paddingBottom: 4,
      }}
    >
      <span
        aria-hidden
        style={{
          width: 5,
          height: 5,
          borderRadius: "50%",
          background: STATUS_COLORS[status],
          flexShrink: 0,
        }}
      />
      <Micro style={{ color: "var(--lc-fg-2)" }}>{status}</Micro>
      <div style={{ flex: 1, height: 1, background: "var(--lc-line)" }} />
      <Micro style={{ color: "var(--lc-fg-4)" }}>
        {String(count).padStart(2, "0")}
      </Micro>
    </div>
  );
}

function SessionRow({
  session,
  now,
  last,
}: {
  session: LidCodeSession;
  now: Date;
  last: boolean;
}) {
  const dim = session.status === "finished";
  return (
    <div
      style={{
        minHeight: 44,
        paddingTop: 14,
        paddingBottom: 14,
        borderBottom: last ? undefined : "1px solid var(--lc-line-soft)",
      }}
    >
      <p
        data-lc-title
        className="lc-clamp-2"
        style={{
          margin: 0,
          color: dim ? "rgba(255,255,255,0.5)" : "var(--lc-fg)",
        }}
      >
        {session.title}
      </p>
      <p style={{ margin: "7px 0 0" }}>
        <Micro>
          {session.agent} · {relativeTime(session.status_changed_at, now)}
        </Micro>
      </p>
    </div>
  );
}

function SessionList({
  sessions,
  index,
}: {
  sessions: LidCodeSession[];
  index: number;
}) {
  const now = new Date();

  const grouped: Record<LidCodeSession["status"], LidCodeSession[]> = {
    running: [],
    blocked: [],
    error: [],
    finished: [],
  };
  for (const s of sessions) grouped[s.status].push(s);

  // Most recently changed first inside each group.
  for (const key of STATUS_ORDER) {
    grouped[key].sort(
      (a, b) =>
        new Date(b.status_changed_at).getTime() -
        new Date(a.status_changed_at).getTime()
    );
  }

  return (
    <Band index={index} style={{ paddingBottom: 8 }}>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 12,
          paddingTop: 24,
          paddingBottom: 20,
        }}
      >
        <Micro style={{ color: "var(--lc-fg-2)" }}>Sessions</Micro>
        <Micro style={{ color: "var(--lc-fg-4)" }}>
          {String(sessions.length).padStart(2, "0")}
        </Micro>
      </div>

      {sessions.length === 0 && (
        <p data-lc-title style={{ margin: "0 0 28px", color: "var(--lc-fg-3)" }}>
          Nothing running.
        </p>
      )}

      {STATUS_ORDER.map((status) => {
        const group = grouped[status];
        if (group.length === 0) return null;
        return (
          <div key={status} style={{ marginBottom: 28 }}>
            <GroupHeading status={status} count={group.length} />
            {group.map((session, i) => (
              <SessionRow
                key={session.id}
                session={session}
                now={now}
                last={i === group.length - 1}
              />
            ))}
          </div>
        );
      })}
    </Band>
  );
}

// ---------------------------------------------------------------------------
// Page shell
// ---------------------------------------------------------------------------

function Screen({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        minHeight: "100dvh",
        background: "#000",
        color: "var(--lc-fg)",
        // Safe area insets for notch / home bar / landscape ears.
        paddingTop: "max(env(safe-area-inset-top), 16px)",
        paddingBottom: "max(env(safe-area-inset-bottom), 32px)",
        paddingLeft: "env(safe-area-inset-left)",
        paddingRight: "env(safe-area-inset-right)",
        boxSizing: "border-box",
        overflowX: "hidden",
      }}
    >
      <div
        style={{
          maxWidth: 480,
          margin: "0 auto",
          padding: "0 20px",
          boxSizing: "border-box",
        }}
      >
        {children}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Dashboard shell — pure presentation, shared by live and demo modes
// ---------------------------------------------------------------------------

function DashboardShell({
  state,
  updatedAt,
  isFetching,
  onSignOut,
  demo = false,
}: {
  state: LidCodeState;
  updatedAt: string | null;
  isFetching: boolean;
  onSignOut?: () => void;
  demo?: boolean;
}) {
  return (
    <Screen>
      <TopRail
        isFetching={isFetching}
        updatedAt={updatedAt}
        demo={demo}
        onSignOut={onSignOut}
      />
      <Hero state={state} />
      <MetricsGrid state={state} />
      <ClaudeAccountsBand state={state} index={2} />
      {state.memory && <MemoryBand memory={state.memory} index={3} />}
      <SessionList sessions={state.sessions} index={4} />
    </Screen>
  );
}

// ---------------------------------------------------------------------------
// Demo dashboard — fixture only, no network, no token. `?demo=1` only.
// ---------------------------------------------------------------------------

function DemoDashboard({ variant }: { variant: "v1" | "v2" }) {
  // Generated once per mount so relative times stay stable while you look at it.
  const [state] = useState(() =>
    variant === "v1" ? createDemoStateV1() : createDemoState()
  );
  return (
    <DashboardShell
      state={state}
      updatedAt={state.pushed_at}
      isFetching={false}
      demo
    />
  );
}

// ---------------------------------------------------------------------------
// Standing states
// ---------------------------------------------------------------------------

function Notice({
  title,
  hint,
  demoLink = false,
}: {
  title: string;
  hint?: string;
  /** Offer the fixture preview. Only useful on the "nothing pushed yet" state. */
  demoLink?: boolean;
}) {
  return (
    <div
      style={{
        minHeight: "100dvh",
        background: "#000",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: "0 24px",
        boxSizing: "border-box",
      }}
    >
      <div style={{ width: "100%", maxWidth: 320 }}>
        <Micro style={{ color: "var(--lc-fg-3)" }}>LidCode</Micro>
        <h1
          data-lc-display
          style={{
            fontSize: 38,
            margin: "20px 0 20px",
            color: "var(--lc-fg)",
          }}
        >
          {title}
        </h1>
        <Rule />
        {hint && (
          <p
            style={{
              margin: "18px 0 0",
              fontSize: 13,
              lineHeight: 1.5,
              letterSpacing: "-0.022em",
              color: "var(--lc-fg-3)",
            }}
          >
            {hint}
          </p>
        )}
        {demoLink && (
          <a
            href="/?demo=1"
            style={{
              display: "inline-flex",
              alignItems: "center",
              minHeight: 44,
              textDecoration: "none",
              WebkitTapHighlightColor: "transparent",
            }}
          >
            {/* Rule on the inner span so it hugs the text, while the anchor
                still carries the 44px touch box. */}
            <span style={{ borderBottom: "1px solid var(--lc-line)", paddingBottom: 8 }}>
              <Micro style={{ color: "var(--lc-fg-2)" }}>
                Preview the layout
              </Micro>
            </span>
          </a>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Token screen
// ---------------------------------------------------------------------------

function LidCodeTokenScreen({ onToken }: { onToken: (t: string) => void }) {
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = value.trim();
    if (!trimmed) {
      setError("Enter your password to continue.");
      return;
    }
    setError(null);
    onToken(trimmed);
  }

  return (
    <div
      style={{
        minHeight: "100dvh",
        background: "#000",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: "0 24px",
        boxSizing: "border-box",
      }}
    >
      <div style={{ width: "100%", maxWidth: 320 }}>
        <Micro style={{ color: "var(--lc-fg-3)", letterSpacing: "0.22em" }}>
          LidCode
        </Micro>
        <h1
          data-lc-display="hero"
          style={{ fontSize: 52, margin: "20px 0 0", color: "var(--lc-fg)" }}
        >
          LOCKED
        </h1>

        <div style={{ height: 32 }} />
        <Rule />

        <form
          onSubmit={handleSubmit}
          style={{
            paddingTop: 24,
            display: "flex",
            flexDirection: "column",
            gap: 14,
          }}
        >
          <div>
            <label htmlFor="lc-token" style={{ display: "block" }}>
              <Micro>Password</Micro>
            </label>
            <input
              id="lc-token"
              type="password"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              autoComplete="current-password"
              autoFocus
              placeholder="••••••••"
              style={{
                display: "block",
                width: "100%",
                height: 52,
                marginTop: 10,
                background: "transparent",
                border: "none",
                borderBottom: "1px solid var(--lc-line)",
                borderRadius: 0,
                color: "#fff",
                // >=16px so iOS Safari does not zoom on focus.
                fontSize: 17,
                letterSpacing: "-0.03em",
                fontFamily: "inherit",
                padding: 0,
                outline: "none",
                boxSizing: "border-box",
              }}
            />
          </div>

          {error && (
            <p role="alert" style={{ margin: 0 }}>
              <Micro style={{ color: STATUS_COLORS.error }}>{error}</Micro>
            </p>
          )}

          <button
            type="submit"
            style={{
              height: 52,
              marginTop: 10,
              background: "#fff",
              color: "#000",
              border: "none",
              borderRadius: 0,
              fontFamily: "inherit",
              fontSize: 11,
              fontWeight: 500,
              letterSpacing: "0.18em",
              textTransform: "uppercase",
              cursor: "pointer",
            }}
          >
            Connect
          </button>
        </form>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Fetch — ETag-aware
// ---------------------------------------------------------------------------

// Module-level ETag cache so the same query function always has the latest tag.
let _lidcodeEtag: string | null = null;

async function fetchLidCodeState(
  token: string
): Promise<
  | { ok: true; state: LidCodeState; updated_at: string }
  | { ok: false; reason: string }
> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
  };
  if (_lidcodeEtag) {
    headers["If-None-Match"] = _lidcodeEtag;
  }

  const res = await fetch("/api/lidcode", { headers, cache: "no-store" });

  if (res.status === 304) {
    // State unchanged — caller keeps its existing data via the sentinel.
    return { ok: false, reason: "__not_modified__" };
  }

  if (res.status === 401) {
    return { ok: false, reason: "unauthorized" };
  }

  const newEtag = res.headers.get("ETag");
  if (newEtag) _lidcodeEtag = newEtag;

  const data = (await res.json()) as
    | { ok: true; state: LidCodeState; updated_at: string }
    | { ok: false; reason: string };
  return data;
}

// ---------------------------------------------------------------------------
// Live dashboard
// ---------------------------------------------------------------------------

function LidCodeDashboard({
  token,
  onSignOut,
}: {
  token: string;
  onSignOut: () => void;
}) {
  // Track visibility so we can pause polling in background tabs.
  const [isVisible, setIsVisible] = useState(true);

  const { data, error, isLoading, isFetching, refetch } = useQuery({
    queryKey: ["lidcode-state"],
    queryFn: () => fetchLidCodeState(token),
    // 60s interval — much less egress than the previous 20s.
    // Polling is suspended entirely when the tab is hidden.
    refetchInterval: isVisible ? 60_000 : false,
    // Keep previous data while a background refetch is in flight.
    placeholderData: (prev) => prev,
  });

  // Visibility-based pause: stop polling when tab is hidden; immediate refresh
  // when it becomes visible again.
  const refetchRef = useRef(refetch);
  refetchRef.current = refetch;

  useEffect(() => {
    function handleVisibilityChange() {
      if (document.hidden) {
        setIsVisible(false);
      } else {
        setIsVisible(true);
        void refetchRef.current();
      }
    }
    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () =>
      document.removeEventListener("visibilitychange", handleVisibilityChange);
  }, []);

  // Cache the last known-good payload so a 304 (__not_modified__) never
  // blanks the dashboard.
  const lastGoodRef = useRef<{
    state: LidCodeState;
    updated_at: string;
  } | null>(null);
  if (data?.ok) {
    lastGoodRef.current = { state: data.state, updated_at: data.updated_at };
  }

  // On 401, clear token and sign out.
  useEffect(() => {
    if (data && !data.ok && data.reason === "unauthorized") {
      clearToken();
      onSignOut();
    }
  }, [data, onSignOut]);

  if (isLoading) return <Notice title="Connecting" />;

  if (error) return <Notice title="No signal" hint={String(error)} />;

  const isNotModified =
    data && !data.ok && data.reason === "__not_modified__";

  if (!data?.ok && !isNotModified) {
    const reason = data?.reason;
    if (reason === "no_data") {
      return (
        <Notice
          title="Standing by"
          hint="Nothing pushed yet. Make sure LidCode.app is running on your Mac."
          demoLink
        />
      );
    }
    if (reason === "storage_not_configured") {
      return (
        <Notice
          title="No storage"
          hint="Add DATABASE_URL in Vercel."
        />
      );
    }
    return <Notice title="Error" hint={reason ?? "Unknown error"} />;
  }

  // Use last good data when we got a 304.
  const current = data?.ok
    ? { state: data.state, updated_at: data.updated_at }
    : lastGoodRef.current;

  if (!current) return <Notice title="Connecting" />;

  return (
    <DashboardShell
      state={current.state}
      updatedAt={current.updated_at}
      isFetching={isFetching && !isLoading}
      onSignOut={onSignOut}
    />
  );
}

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

function LidCodeRoot() {
  const [token, setToken] = useState<string | null>(null);
  const [mounted, setMounted] = useState(false);
  const [demoVariant, setDemoVariant] = useState<"v1" | "v2" | null>(null);

  useEffect(() => {
    // Read the flag from location rather than useSearchParams so the page stays
    // a plain client component with no Suspense boundary requirement.
    setDemoVariant(getDemoVariant(window.location.search));
    setToken(getStoredToken());
    setMounted(true);
  }, []);

  const handleSignOut = useCallback(() => setToken(null), []);

  // Avoid a hydration-mismatch flash: hold pure black until localStorage is read.
  if (!mounted) {
    return <div style={{ minHeight: "100dvh", background: "#000" }} />;
  }

  // Demo mode short-circuits auth and networking entirely.
  if (demoVariant) return <DemoDashboard variant={demoVariant} />;

  if (!token) {
    return (
      <LidCodeTokenScreen
        onToken={(t) => {
          saveToken(t);
          setToken(t);
        }}
      />
    );
  }

  return <LidCodeDashboard token={token} onSignOut={handleSignOut} />;
}

// ---------------------------------------------------------------------------
// Page export
// ---------------------------------------------------------------------------

export default function Home() {
  return (
    <QueryClientProvider client={queryClient}>
      <LidCodeRoot />
    </QueryClientProvider>
  );
}
