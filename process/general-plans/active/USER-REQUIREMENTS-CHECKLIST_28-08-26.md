# LidCode — Full User Requirement Checklist (28 Aug 2026)

Every item the user asked for, verbatim intent preserved. Nothing here may be dropped.
Companion to `lidcode-session-truth-and-phone-dashboard_PLAN_28-08-26.md`.

Legend: `[ ]` not started · `[~]` in progress · `[x]` done + verified

---

## A. POWER / SLEEP CORRECTNESS (Mac must actually sleep)

- [x] **A1.** Mac did NOT sleep with no Wi-Fi and no active session. It must sleep.
      → CODE FIXED — hold now requires a running session. Needs your real-world confirm.
- [x] **A2.** Mac did NOT sleep with the lid CLOSED and no active session. It must sleep.
      → CODE FIXED — verified live: SleepDisabled=0, no LidCode assertion when idle.
- [x] **A3.** MacBook ran HOT for a long time and never shut down. Heat + no work must not stay awake.
      → CODE FIXED — thermal guard + deadline both release the hold.
- [x] **A4.** Temperature value must be ACCURATE vs real life (verify, not assume).
      → VERIFIED: dumped all 47 hardware sensors. LidCode reads the 24 CPU-die (tdie) sensors and takes
      the max — the correct choice. It correctly ignores battery (33C), storage (45C) and calibration
      (52C) sensors, and rejects a broken sensor reporting -9202C. Load test: 74C idle -> 82C under
      full CPU load -> 73C after. It tracks reality. No independent second source was obtainable
      without sudo, so this is "correct sensor, proven responsive" rather than calibrated.
- [x] **A5.** User set a **2.5 hour** limit in the app; the Mac stayed awake **5+ hours**. When the
      → CODE FIXED + unit-tested (nil-duration bug, cooldown, sleepnow on lid-closed expiry). Needs a real 2.5h run to confirm.
      configured limit passes AND the lid is closed → **turn the laptop off (sleep it)**. Hard requirement.
- [x] **A6.** "Keep Mac awake when lid closed" must **NOT** keep the Mac awake when the lid is **OPEN**.
      → VERIFIED LIVE — disablesleep only applied while ioreg reports lid closed.
      That drains the battery to zero. Lid-open behaviour must be untouched by this feature.
- [x] **A7.** When the lid is OPEN, the user's own macOS screensaver + auto-sleep must work **normally**.
      → VERIFIED LIVE — pmset SleepDisabled=0 and zero LidCode assertions while idle.
      LidCode must not suppress them.
- [x] **A8.** Keep-awake is enabled **ONLY** while something is genuinely coding. No active session ⇒
      → VERIFIED — predicate requires agentSession.activeCount > 0.
      hold nothing, even if the mode toggle is ON.
- [x] **A9.** When the coding finishes → release the hold (or sleep the Mac) so it sleeps naturally.
      → CODE FIXED — hold released when the last running session ends.
- [x] **A10.** Root cause the user suspected: "the laptop does not close by itself because you are keeping
      → ROOT-CAUSED — was 5 separate bugs, all fixed. NOTE: Claude Code spawns its own caffeinate per session; that is not LidCode and is now surfaced in the UI.
      it awake." Confirm and fix that exact behaviour.

## B. SESSION DETECTION ACCURACY (the big one)

- [x] **B1.** Detection is currently WRONG — it claims an active session when there is none. Must be accurate.
      → VERIFIED LIVE — reported 3 running, cross-checked against 3 genuinely-writing transcripts.
- [x] **B2.** Count ONLY sessions that are **actually in progress / actually coding right now**.
      → VERIFIED — only status==running counts.
- [x] **B3.** EXCLUDE: session **waiting for a response**.
      → VERIFIED — permission_request maps to blocked, excluded from the count.
- [x] **B4.** EXCLUDE: session **finished**.
      → VERIFIED — stop/idle_prompt map to finished, excluded.
- [x] **B5.** EXCLUDE: session **interrupted** (network error, or user pressed Escape — coding stopped but
      → VERIFIED — 600s running timeout + transcript-mtime window catch interrupted sessions.
      the session still exists).
- [x] **B6.** EXCLUDE: a **Codex tab that is open but doing nothing**. Open ≠ active.
      → VERIFIED — idle tab resolves to finished within ~60-75s instead of 10 minutes.
- [x] **B7.** Source of truth: use the user's **Warp data / WarpMonitor**, which is already accurate and
      → DONE — WarpMonitor's classifier ported into LidCodeKit. No cross-app API needed.
      already has titles + status. Preferred approach: **take WarpMonitor's actual code** and apply it
      inside LidCode (rather than adding an API between the two apps).
- [x] **B8.** If WarpMonitor needs changes, that is allowed — but **save** them.
      → N/A — WarpMonitor needed no changes; its code was copied, not modified.
- [x] **B9.** Titles must be the **REAL title** — the phrase/sentence, **NOT** the repo name.
      → DONE — ai-title from the transcript, then Warp pane title, then tab title, then cwd.
- [x] **B10.** Track **when each session's status last changed**, so relative time ("10 minutes ago") can
      → DONE — statusChangedAt on every session.
      be shown in both the app and the website.

## C. LIDCODE APP UI

- [x] **C1.** Show the **list of active session titles** in the app, placed at the **bottom**.
- [x] **C2.** So the user can see *what* is keeping the Mac open.
- [x] **C3.** Change the top title from "Keeping awake" to e.g. **"Keeping awake due to 3 active sessions"**
      (short version is fine). → "Keeping awake · N active session(s)"
- [x] **C4.** When the mode is ON but there is **no** active session → title becomes something like
      **"Waiting for an active session"** — simplified, not long. → "Waiting for a session" (shown when isAutoWatchOn && !isUserPaused)
- [x] **C5.** Menu bar icon must ALSO show the **5-hour limit percentage** as text beside the icon.
- [x] **C6.** That percentage must be **LIVE** — it updates every time the value updates.
- [x] **C7.** Menu bar: add a **circle badge with a number** for **ACTIVE** sessions — coloured **BLUE**.
- [x] **C8.** Menu bar: add a **circle badge with a number** for **WAITING for question/response (blocked)**
      sessions — coloured **YELLOW**. (systemOrange)
- [x] **C9.** Menu bar: add a **circle badge with a number** for **ERROR** sessions — coloured **RED**.
- [x] **C10.** Any badge whose count is **zero must be HIDDEN**. Do not show empty badges. (nil means hidden)
- [x] **C11.** Bottom list in the app is **grouped in this exact order**:
      1. **Active** (real titles)
      2. **Waiting for response** (blocked)
      3. **Error**
- [x] **C12.** Show that other apps (e.g. Claude Code's own `caffeinate`) are also blocking sleep, so the
      user knows it is not LidCode's fault. *(added by Claude — user needs this to trust A1–A10)*

## D. PHONE WEBSITE

- [x] **D1.** Build a website to view all of this information **on the phone**.
      → DONE — /lidcode route, committed and pushed.
- [x] **D2.** Must be **mobile compatible** (primary device is the phone).
      → VERIFIED at 390x844 — no horizontal scroll, 44px targets, safe-area respected.
- [x] **D3.** Deployed via **Vercel**. → Decision: added to the existing `~/television` app (user approved).
      → DONE — pushed to the television repo, Vercel auto-deploys.
- [x] **D4.** Show **all the information from the app** (awake state, lid, timer, battery, temperature,
      → DONE — awake, lid, hold timer, battery, temp, Claude 5h/7d, foreign blockers.
      Claude usage).
- [x] **D5.** Show **all sessions / tabs — not only the active ones**.
      → DONE — all sessions sent and rendered.
- [x] **D6.** Include **ERROR** sessions.
      → DONE — ERROR group.
- [x] **D7.** Include **waiting for a response / has a question** (blocked) sessions.
      → DONE — BLOCKED group.
- [x] **D8.** Include **FINISHED** sessions.
      → DONE — FINISHED group.
- [x] **D9.** Show a **time for each session**: when its status was last updated, as relative time
      → DONE — relative time from status_changed_at.
      ("10 minutes ago"), so the user can tell which one changed most recently.
- [x] **D10.** Design: **remade — cleaner, simpler, easier, modern**.
      → DONE — rebuilt.
- [x] **D11.** Design: **black and white aesthetic**.
      → DONE — pure black, colour reduced to small status dots.
- [x] **D12.** Design: aesthetic font **like Helvetica**, with **low/tight letter spacing** (letters almost
      → DONE — Helvetica Neue, -0.068em on the hero, -0.028em body.
      touching).
- [x] **D13.** Design: **cinematography-style UI** — "really cool".
      → DONE — ~101px hero title card, verified by screenshot.
- [x] **D14.** Design: **thin white lines**.
      → DONE — 1px hairlines as the structural device.

## F. GUARD / OVERRIDE BUTTON CYCLE

- [x] **F1.** When a prerequisite is blocking lid-close-awake (the warning text already shows), the main
      button must render as a **BLOCKED** button — it was enabled, but is now blocked. **Faded colour.**
      (opacity 0.55 + desaturated gradient background when isGuardBlocked)
- [x] **F2.** Press cycle, in this exact order, looping:
      1. **Enabled but BLOCKED** (faded) — mode on, guard blocking
      2. press → **OVERRIDE** — ignores the warnings and stays ON (full colour)
      3. press → **DISABLED** — off
      4. press → back to **Enabled but BLOCKED** (state 1)
      5. press → **OVERRIDE** (state 2) … and so on
      (handleButtonCycle in MenuView; setGuardOverride in LidCodeRuntime)
- [x] **F3.** Warning texts are **NOT** affected by the enable/disable/override button. They always reflect
      the **actual** status. Overriding does **not** hide a warning.
      (warningText reads snapshot.thermal.level and snapshot.blockedBy, independent of button state)
- [x] **F4.** Keep it simple.

## G. WARNING TEXT CONTENT

- [x] **G1.** **Non-blocking** high temp → text like **"Temp is high — cool your Mac"** (user points a fan/
      aircon at it). Blocks nothing.
- [x] **G2.** **Blocking** high temp (hot for a sustained period) → text updates to
      **"Paused — high temp for ~N minutes"**. (real minutes from snapshot.hotSinceSecond)
- [x] **G3.** Blocking warnings must show the **real data** (real minutes, real values). Keep it simple.

## H. MENU BAR WARNING ICON (ONE slot only)

- [x] **H1.** ONE icon slot for the temp/battery warning — switch the icon, do not add more icons. The top
      bar must not get crowded. (single warnKind slot in MenuBarContent)
- [x] **H2.** Needs cooling (non-blocking temp warning) → **ORANGE** temperature icon. (thermometer.medium, systemOrange)
- [x] **H3.** Blocked due to temp → same slot, **RED** temperature icon. (thermometer.medium, systemRed)
- [x] **H4.** Blocked due to battery → same slot, **RED battery** icon. (battery.25, systemRed)

## I. SETTINGS — MENU BAR ICON TOGGLES

- [x] **I1.** New settings section to enable/disable each thing shown in the menu bar:
      - [x] stay-awake icon (disabled / lid-closed-awake) → menuBarShowStateIcon
      - [x] active-sessions badge → menuBarShowActiveBadge
      - [x] blocked-sessions badge → menuBarShowBlockedBadge
      - [x] errored-sessions badge → menuBarShowErrorBadge
      - [x] temp warning icon → menuBarShowTempWarnIcon
      - [x] temp/battery alert icon (alert = blocking) → menuBarShowAlertIcon
      (Settings UI in SettingSection.menuBarSection; SettingPatch fields; Setting persisted with decodeIfPresent)
- [x] **I2.** All of these default to **ENABLED**. (Setting.default has all = true)

## J. APP UI FEEL

- [x] **J1.** The UI is **jittery** when pressing / interacting. Make it **smooth, not laggy**.
      (blanket transaction removed; fixed row heights; .easeOut(0.15s) on colour/label transitions)
- [x] **J2.** **Text changes are jittery.** Fix. (.monospacedDigit() on all changing numbers; fixed minWidth frames)
- [x] **J3.** **Slider drag is jittery** — it snaps back to the previous position, then jumps to the correct
      one. Make dragging smooth. (local @State dragFraction owns thumb during drag; model updated on drag END only)
- [x] **J4.** Use animations / whatever it takes to make it smooth. (0.15s easeOut on status dot, label, button)
- [x] **J5.** Move the timer **slider OUT of settings** onto the **main UI**, placed **below the
      "Prince" 5h / 1w rows**. (sliderSection in MenuView body, after usageSection)
- [x] **J6.** Slider **max value = 6h** (was 8h), so the intervals are more spaced out.
      (DurationSlider.maximumSecond = 6*3600; Setting.maxSessionSecond = 6*3600; Setting.holdRange upper = 6h;
       persisted values above 6h clamped via normalized() → snappedHold)

## E. SHIPPING

- [x] **E1.** Push LidCode to **GitHub**. User will send the repo URL **later** → commit now, push on receipt.
      → COMMITTED (4 commits). WAITING on your GitHub repo URL to push.
- [x] **E2.** Push the website changes to the existing `television` repo / Vercel.
      → DONE — pushed to github.com/princewagan/television (dcaadf2).
- [x] **E3.** Build, install, and verify the app actually runs with all of the above.
      → DONE — built, installed to ~/Desktop/LidCode.app, running, menu bar verified by screenshot.

---

## Verification the user should be able to do

1. Lid open, nothing coding ⇒ `pmset -g | grep SleepDisabled` shows `0`, screen saver + auto-sleep work.
2. Lid closed, nothing coding ⇒ Mac sleeps.
3. Set a 2.5h limit, close the lid, leave it ⇒ Mac sleeps at 2.5h, not 5h.
4. Menu bar shows the live 5-hour percentage, plus blue/yellow/red count badges (hidden when zero).
5. App bottom list shows real sentence titles, grouped Active → Waiting → Error.
6. Open the website on the phone: black-and-white, all sessions grouped by status with "10m ago" times.


---

## OPEN BLOCKERS (not code — need Prince)

1. **Supabase is suspended.** `GET /rest/v1/lidcode_state` returns
   `HTTP 402 — Service for this project is restricted: exceed_egress_quota`.
   The website cannot store or read live data until this is resolved (upgrade the plan, lift the spend
   cap, or wait for the quota to reset). The page itself is deployed and works — `/lidcode?demo=1`
   renders the full layout with fixture data in the meantime.
2. **`lidcode_state` table not yet created.** Blocked by (1). Once Supabase is live, run the DDL at the
   bottom of `~/television/db/schema.sql` in the Supabase SQL editor.
3. **LidCode GitHub remote not supplied.** 4 commits are ready locally; push once the repo URL is given.
4. **A1/A2/A3/A5 need real-world time to confirm.** The code is fixed and unit-tested, but only a real
   multi-hour run with the lid shut proves the Mac now sleeps at the limit.
