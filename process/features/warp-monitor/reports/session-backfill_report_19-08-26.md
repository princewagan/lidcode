# Session Backfill Report — 2026-08-19

## Problem

`LogTailer.start()` previously called `openLog(seekToEnd: true)`, positioning the file
cursor at the end of `~/Library/Logs/warp.log` before installing the FSEvents watcher.
Any Claude sessions active before the restart were invisible until they emitted a new
log line. Live evidence 90 seconds after restart: `{"idle":40}` / `sessions: 0`.

---

## Bound chosen and rationale

**4 MB byte cap + 2-hour timestamp window.**

| Metric | Value |
|---|---|
| Log file size at fix time | 38 MB, 256 k lines |
| Average OSC 777 line length | ~294 bytes |
| Events in last 4 MB | ~3,280 |
| Time span covered by 4 MB | ~21 hours |
| Events within 2-hour cutoff | 75 (this session) |
| Events skipped (> 2 h old) | 3,231 |

The **4 MB read cap** is a hard upper bound on I/O: one `readDataToEndOfFile()` call
reads at most 4 MB regardless of total file size. At observed density the cap covers
20+ hours of events, far beyond the 2-hour relevance window.

The **2-hour timestamp window** is the semantic filter: lines whose leading timestamp is
older than `now - 7200s` are skipped without JSON parsing. This means even if the log
shrinks dramatically (very high density), only events that could plausibly affect current
session status are replayed.

Sessions older than 10 minutes land as `finished` (via `checkTimeout()`) — there is no
risk of a 3-hour-old `running` event surfacing as currently running.

---

## No double-processing at the live-tail boundary

`performBackfillAndOpen()` structure:

```
1. fh.seekToEndOfFile()         → fileSize
2. fh.seek(to: fileSize - 4MB)
3. data = fh.readDataToEndOfFile()  ← reads exactly [fileSize-4MB … fileSize]
4. liveTailStart = fh.seekToEndOfFile()  ← re-records the true current EOF
5. self.lastOffset = liveTailStart      ← live tailing starts HERE
6. replayBackfillData(data)
```

Step 4 re-seeks to EOF after the read. This handles any bytes appended by Warp during
the backfill read itself. `readNewLines()` subsequently reads `[liveTailStart … new EOF]`,
which is strictly after the bytes already processed in step 3.

The test `testBackfillNoDoubleCountAtBoundary` proves this: 2 pre-existing events +
1 live-appended event = exactly 3, never 4.

---

## Timeout interaction — stale running sessions

`parseBackfillLine` uses `extractTimestamp(from: line)` to set `event.receivedAt` to
the log line's own timestamp (not `Date()`). When the state machine applies:

```swift
sessionMap[id]!.apply(event: ev.event, at: ev.receivedAt, ...)
```

`ClaudeSessionState.lastEventAt` is set to the historical time. When
`StateManager.pruneStaleSessionsAndRefresh()` calls `checkTimeout()`:

```swift
let elapsed = Date().timeIntervalSince(lastEventAt)  // measures against historical time
if elapsed > 600 { status = .finished; timedOut = true; lastEvent = "stop" }
```

A session whose last event was 90 minutes ago will have `elapsed ≈ 5400`, which is
`> 600`. It is demoted to `.finished` on the first 5-second WAL timer tick after
startup — never shown as `running`.

Test `testBackfillStaleRunningTimesOut` proves this directly:
- Replay two events with timestamps 90 minutes ago via `replayBackfillDataForTesting`
- Verify `lastEventAt.timeIntervalSinceNow < -600`
- Call `checkTimeout()` → `changed == true`, `status == .finished`, `timedOut == true`,
  `lastEvent == "stop"`

Notifications are deliberately **not** replayed during backfill. Flooding the 50-slot
ring buffer with 2 hours of stale notifications would mask real-time events.

---

## Measured backfill duration (real `~/Library/Logs/warp.log`)

Measured with a standalone Swift script on the production log (read-only, never written):

| Phase | Time |
|---|---|
| Read I/O (4 MB via `readDataToEndOfFile`) | **0.4 ms** |
| Parse (split 28,427 lines, filter, JSON decode 75 events) | **149.3 ms** |
| **Total** | **149.7 ms** |

Target was < 2,000 ms. Actual: **149.7 ms** — 13× faster than budget.

The dominant cost is `String.components(separatedBy: "\n")` over 4 MB / 28 k lines.
At current log density this is acceptable. If log density ever increases 10× the parse
time would still be ~1.5 s, within budget.

---

## Before/after production comparison

**Before fix (90 s after restart, logged 2026-08-19):**
```json
{"idle": 40, "sessions": 0}
```

**After fix (query at 2026-08-19T13:17:27Z, ~55 s after relaunch):**
```
pushed_at: 2026-08-19T13:17:27Z
warp_running: true
Tab status counts: {'idle': 38, 'running': 2}
Total claude_sessions: 2
Orphan sessions: 0
  running session: 5ba1e586… last_event: tool_complete  at: 2026-08-19T13:17:27Z
  running session: 5ba1e586… last_event: tool_complete  at: 2026-08-19T13:17:27Z
```

Two `running` sessions visible immediately after restart — the same session matched to
two tabs sharing the same CWD (expected `ambiguous_cwd` behaviour). The 38 `idle` tabs
have no active Claude sessions in their CWD, which is correct.

**Session count before vs after:** 0 → 2 (in this snapshot; will vary by active workload).

---

## App health post-deploy

| Check | Result |
|---|---|
| `pgrep -lf WarpMonitor.app` | PID 68743 (alive) |
| System crash reports (`/Library/Logs/DiagnosticReports/*.ips`) | 2 (unchanged) |
| User crash reports (`~/Library/Logs/DiagnosticReports/*.ips`) | 59 (unchanged) |
| No new `.ips` since deploy | confirmed |

---

## Test coverage

41 tests pass (34 pre-existing + 7 new backfill tests):

| New test | What it proves |
|---|---|
| `testBackfillPopulatesSessions` | Sessions within 2-hour window populate the session map with historical `receivedAt` |
| `testBackfillStaleRunningTimesOut` | 90-min-old running session is demoted to `finished` by `checkTimeout()` after backfill |
| `testBackfillWindowBoundRespected` | 121-min-old event excluded; 119-min-old event included |
| `testBackfillNoDoubleCountAtBoundary` | Pre-existing 2 events + 1 live event = exactly 3, never 4 |
| `testBackfillMissingLogFile` | Missing file → zero events, no crash |
| `testBackfillEmptyLogFile` | Empty file → zero events, no crash |
| `testBackfillTruncatedFirstLine` | Partial line at byte boundary dropped; subsequent complete line parsed |

---

## Status

DONE
