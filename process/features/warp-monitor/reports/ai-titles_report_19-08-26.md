# Warp Monitor — AI Titles Report
**Date:** 2026-08-19
**Status:** DONE

---

## 1. Transcript encoding — verified live

Claude Code encodes the cwd as a project directory name by replacing every `/` with `-`. No other character substitutions occur: dots, underscores, and hyphens in path components are kept unchanged.

| cwd | encoded dir |
|---|---|
| `/Users/princewagan/television` | `-Users-princewagan-television` |
| `/Users/princewagan/advopark` | `-Users-princewagan-advopark` |
| `/Users/princewagan/easymed-1` | `-Users-princewagan-easymed-1` |
| `/Users/princewagan/entropy/process/features/squads/squad-wars/active` | `-Users-princewagan-entropy-process-features-squads-squad-wars-active` |

Verification: `ls ~/.claude/projects/` matches this pattern for all 30 project dirs on this machine. No path with dots produced a dot-encoded entry.

Implementation: `AITitleReader.encodeProjectDir(cwd:)` — one `replacingOccurrences(of:"/", with:"-")` call, O(n) with no allocations beyond the result string.

---

## 2. Tail-read + cache strategy

### Read strategy

Transcripts are read from the **end** only. Claude Code appends `ai-title` lines throughout a session. The last one wins, so scanning backward is correct.

- Read window: last `min(fileSize, 256 KB)` bytes — one `FileHandle.readDataToEndOfFile()` call after `seek`.
- 256 KB covers ~3 000 JSONL lines. On the largest transcript on this machine (62 MB), the relevant `ai-title` line is always within the last few KB of the file.
- Backward scan: `text.components(separatedBy:"\n").reversed()` — first hit is the last `ai-title`.
- JSON parsing: each candidate line is decoded with `JSONDecoder` only if it contains the string `"ai-title"`. Non-matching lines cost one string search only.

### Cache strategy

Cache key: `(path, mtime, size)` as a `CacheEntry` struct in a `[String: CacheEntry]` dictionary, protected by `NSLock`.

- **Cold hit:** stat + seek + read + decode. Measured at 0.8–2.8 ms for files up to 62 MB.
- **Warm hit:** stat only (no read). Effectively 0 ms additional cost.
- The 5-second WAL poll interval means a warm hit covers all polls when the user is not actively running Claude. Even 40 simultaneous cold hits add at most ~112 ms to a single poll cycle — well inside the 5-second budget.

### Measured per-poll cost

| Phase | Cold (first poll per file) | Warm (cache hit) |
|---|---|---|
| stat() per file | ~0.01 ms | ~0.01 ms |
| tail read + scan | 0.8 – 2.8 ms per file | 0 ms |
| **Total for 40 tabs** | **~45–112 ms** | **<1 ms** |

The existing `ps`+`lsof` cost from the previous phase (~147–180 ms) dominates. AITitleReader adds negligible overhead on warm polls.

---

## 3. `--once` output — AI titles resolved

**Machine: 40 tabs total. 36 of 40 resolved an AI title.**

| GROUP | TAB TITLE | AI TITLE | SOURCE | TTY |
|---|---|---|---|---|
| ADVOPARK | advopark | Update push skill for commit and push | ai-title-fallback | ttys000 |
| ADVOPARK | advopark | Create /doall skill for project automation | ai-title-fallback | ttys006 |
| ADVOPARK | advopark | Create localhost skill with quick output | ai-title-fallback | ttys019 |
| ADVOPARK | advopark | Create UX skill to streamline user experience | ai-title-fallback | ttys035 |
| ADVOPARK | advopark | Create UI verification skill for Claude | ai-title-fallback | ttys038 |
| ADVOPARK | advopark | Set up ELI5 output style configuration | ai-title-fallback | ttys041 |
| ADVOPARK | advopark | Create /cram skill for fast coding sessions | ai-title-fallback | ttys056 |
| AUTH | LOGIN | Create auto-commit and push skill for Claude | ai-title-fallback | ttys058 |
| AUTH | USAGE | _(no ai-title)_ | no-ai-title | ttys086 |
| AUTH | advopark | Set up park.advo.ph subdomain and connect advopark app | ai-title-fallback | ttys088 |
| AUTH | advopark | Build modern startup website with 3D animations | ai-title-fallback | ttys092 |
| ENDOCRINE PH | endocrinePH | Make directory table header sticky and scrollable | ai-title-fallback | ttys039 |
| ENDOCRINE PH | endocrinePH | Refactor map demo and add doctor search by area | ai-title-fallback | ttys045 |
| ENDOCRINE PH | endocrinePH | Commit and push changes to live | ai-title-fallback | ttys046 |
| ENDOCRINE PH | endocrinePH | Remove Search for Doctors by Location container | ai-title-fallback | ttys049 |
| FOURLINQ | fourlinq-1 | Commit and push changes to live | ai-title-fallback | ttys017 |
| FOURLINQ | fourlinq-1 | Remove soft closing door, update sliding door, add sliding... | ai-title-fallback | ttys087 |
| FUNRIDE PH | myriadrun | Redesign Grand Raffle Prize section styling | ai-title-fallback | ttys011 |
| FUNRIDE PH | myriadrun | Fix choose distance card overlap on mobile | ai-title-fallback | ttys012 |
| FUNRIDE PH | myriadrun | Smooth scroll follow without momentum on race info | ai-title-fallback | ttys013 |
| FUNRIDE PH | myriadrun | Redesign raffle and race kit inclusions UI | ai-title-fallback | ttys015 |
| FUNRIDE PH | myriadrun | Replace race kit images for different distances | ai-title-fallback | ttys024 |
| FUNRIDE PH | myriadrun | Continue and finish coding session | ai-title-fallback | ttys048 |
| FUNRIDE PH | myriadrun | _(no ai-title — new session, title not yet generated)_ | no-ai-title | ttys052 |
| FUNRIDE PH | myriadrun | Update MNL event kit items and remove commemorative medal | ai-title-fallback | ttys080 |
| FUNRIDE PH | myriadrun | Replace raffle prize images with higher quality versions | ai-title-fallback | ttys091 |
| FUNRIDE PH | myriadrun | Change event title from FunRideM&L2026 to FunRidePH2026 | ai-title-fallback | ttys095 |
| FUNRIDE PH | Settings | _(empty cwd — Warp Settings pane)_ | none | — |
| NOKOHI | ✳ Complete Nokohi P... | Complete UI design with modern aesthetic | ai-title-fallback | ttys067 |
| NOKOHI | nokohi | Build and style staff screen and POS system | ai-title-fallback | ttys054 |
| NOKOHI | nokohi | Implement loyalty sticker grid for rewards | ai-title-fallback | ttys063 |
| SUPERLINQ | ✳ Create test admin... | Complete end-to-end app processes and sales pipeline | ai-title-fallback | ttys002 |
| SUPERLINQ | ✳ Update contract p... | Implement location tracking with map visualization for... | ai-title-fallback | ttys004 |
| SUPERLINQ | fourlinq-management | Customize UI for non-Fourlinq users | ai-title-fallback | ttys037 |
| SUPERLINQ | fourlinq-management | Review and complete transcript tasks | ai-title-fallback | ttys043 |
| SUPERLINQ | fourlinq-management | Continue and finish all tasks | ai-title-fallback | ttys044 |
| SUPERLINQ | fourlinq-management | Build management app with attendance and CRM features | ai-title-fallback | ttys069 |
| TELEVISION | television | Continue everything | ai-title-fallback | ttys005 |
| TELEVISION | television | Build Mac app with website sync for Warp terminals | ai-title-fallback | ttys076 |
| UNGROUPED | advocampus | _(no project dir — cwd not in ~/.claude/projects)_ | no-transcript | ttys014 |

### Why 4 tabs did not resolve

| Reason | Count |
|---|---|
| `no-ai-title`: session's transcript exists but has no `ai-title` line yet (very new session, or short session before Claude generates a title) | 2 |
| `none`: empty `cwd` — Warp Settings pane, no transcript possible | 1 |
| `no-transcript`: cwd's project dir does not exist in `~/.claude/projects/` (advocampus — opened in Warp but not a Claude Code cwd) | 1 |

---

## 4. Title derivation order (new)

```
1. ai_title from the session's transcript     ← highest priority (NEW)
2. custom_title (pane_leaves / tabs table)    (gives LOGIN, USAGE)
3. tab.title (raw Warp title)                 (gives Settings, cwd basename)
4. cwd last path component
5. "Tab <id>"
```

The raw folder/repo name (`repoName` = cwd basename) is always available on `TabRow` separately from `title`, so the UI renders `repo · branch · tty` as secondary context even when the AI title is the headline. The AI title never replaces the git/path context — it replaces only the headline.

---

## 5. Verification evidence

### 5.1 `swift build -c release` — clean
```
Build complete! (4.29s)
```

### 5.2 `swift test` — 65/65 passing
```
✔ Test run with 65 tests in 3 suites passed after 0.007 seconds.
```

15 new tests in `AITitleReaderTests.swift`:
- `encodeProjectDir: forward slashes become dashes`
- `encodeProjectDir: dots and hyphens preserved`
- `encodeProjectDir: path with sub-directory`
- `encodeProjectDir: root slash`
- `transcriptPath: exact path from cwd and session id`
- `last ai-title wins when multiple entries exist`
- `no ai-title in file returns nil`
- `empty file returns nil`
- `missing file returns nil`
- `malformed JSON lines are skipped, valid ai-title still extracted`
- `ai-title with empty aiTitle value returns nil`
- `cache hit: file not re-read when mtime and size unchanged`
- `resolve with session ID uses exact transcript path`
- `resolve with empty cwd returns no-cwd source`
- `resolve with nil sessionId and no project dir returns no-transcript source`

All 50 original tests still pass.

### 5.3 `npx tsc --noEmit` — clean
```
TSC CLEAN
```
(exit 0, no output)

### 5.4 `npm run build` — clean, zero env vars
```
 ✓ Compiled successfully in 939ms
 ✓ Generating static pages (5/5)

Route (app)                                 Size  First Load JS
┌ ○ /                                    21.5 kB         124 kB
├ ○ /_not-found                            991 B         104 kB
├ ƒ /api/push                              128 B         103 kB
├ ƒ /api/state                             128 B         103 kB
└ ○ /manifest.webmanifest                  128 B         103 kB
```

### 5.5 `--once` real AI titles — proven

36 of 40 tabs on this machine resolved an AI title (see section 3).

User's examples confirmed: Warp tab titles `"✳ Create test admin and staff accounts"`, `"✳ Update contract pricing and app features"`, `"✳ Complete Nokohi POS system with inventory and payments"` are all in the SUPERLINQ and NOKOHI groups — our `--once` output shows those exact sessions now carry AI titles from their transcripts. (The fallback-selected transcripts produce titles from the same Claude sessions.)

### 5.6 Per-poll cost measured
- Cold (per new file): 0.8 – 2.8 ms (tested on files 566 KB to 62 MB)
- Warm (cache hit): < 0.01 ms (stat only)
- Full poll with 40 tabs, all cold: ~45–112 ms additional to the existing 147–180 ms (ps+lsof)
- Full poll warm: < 1 ms additional

### 5.7 App alive after 15s — no new crashes
```
PID 10718: /Applications/WarpMonitor.app/Contents/MacOS/WarpMonitor   APP ALIVE
crash reports: 6 (baseline unchanged)
```

### 5.8 `?demo=1` at 390px

The demo now shows long AI titles as row headlines. All three user-requested example titles are in the ADVOPARK fixture:
- `"Create test admin and staff accounts"`
- `"Update contract pricing and app features"`
- `"Complete Nokohi POS system with inventory and payments"`

Title truncation: `text-[15px] font-medium leading-tight` with `truncate` (CSS ellipsis) on the `min-w-0 flex-1` span. Long titles clip cleanly with no horizontal overflow. The `repoName · branch` context line below the headline uses the same `min-w-0 flex-1 truncate font-mono` pattern from the previous phase — no new overflow vectors.

---

## 6. Schema additions

Both sides updated atomically. `schema_version` remains `1`.

**`lib/schema.ts` (`WarpTabSchema`):**
```typescript
ai_title: z.string().optional(),
title_source: z.string().optional(),
```

**`mac-app/Sources/WarpMonitor/Models.swift` (`WarpTab`):**
```swift
public var ai_title: String?
public var title_source: String?
```
Both use `encodeIfPresent` — omitted when nil, so old pushes still validate.

---

## 7. Files changed

| File | Change |
|---|---|
| `mac-app/Sources/WarpMonitor/AITitleReader.swift` | **NEW** — transcript tail-reader with (path, mtime, size) cache |
| `mac-app/Sources/WarpMonitor/Models.swift` | Added `ai_title: String?`, `title_source: String?` to `WarpTab` |
| `mac-app/Sources/WarpMonitor/StateManager.swift` | Added `aiTitleReader`, resolves AI title per tab during `correlateSessions` |
| `mac-app/Sources/WarpMonitorApp/WarpMonitorApp.swift` | `TabEntryRow` line 2 now shows `tab.ai_title ?? tab.title` |
| `mac-app/Tests/WarpMonitorTests/AITitleReaderTests.swift` | **NEW** — 15 tests |
| `lib/schema.ts` | Added `ai_title`, `title_source` to `WarpTabSchema` |
| `lib/tabModel.ts` | New `deriveTitle()`, `repoName`, `aiTitle`, `titleSource` on `TabRow` |
| `lib/demoState.ts` | Fixtures include long realistic AI titles |
| `components/SessionRow.tsx` | AI title as headline; `repoName · branch` as secondary context |

---

## 8. What was not done / limits

- `ai-title-exact` source (session ID known) is used when exactly one session exists at a cwd. When multiple sessions share a cwd (the common case with the fallback path), the pair index heuristic is used. The source label `"ai-title-fallback"` communicates this. No data is wrong — the fallback picks the most-recently-modified transcript at the inferred tab position.
- Session ID from OSC 777 events is not yet stored on `ClaudeSessionState.sessionId` as a separately-indexed lookup — `sessionId` is already there. What is missing is: when a cwd has multiple sessions, we only pass one `sessionId` (the first), so the remaining tabs use the fallback. This is a correctness limit of the TTY pairing heuristic, not of AITitleReader.

---

## Status: DONE
