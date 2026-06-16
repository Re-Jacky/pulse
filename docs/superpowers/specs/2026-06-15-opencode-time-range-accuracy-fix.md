# OpenCode Time-Range Token Accuracy Fix

**Date:** 2026-06-15
**Status:** Ready for Review

## Goal

Fix OpenCode token totals for `Today`, `7 Days`, and `30 Days` ranges so they reflect actual message activity within the time window instead of each session's cumulative lifetime totals.

## Root Cause

`AgentUsageStore.derivedData()` calls `state.openCodeSnapshot.filtered(to: selection.timeRange)`. The filter keeps sessions whose `updatedAt` falls within the range, but each `OpenCodeSessionRecord` carries cumulative lifetime token totals from `session.tokens_*` columns. A session created weeks ago and touched today reports all its historical tokens, especially `tokens_cache_read`, which can exceed 100M tokens over a long session.

## Background — What Changed

The 2026-06-12 data-flow refactor spec chose in-memory session filtering over per-message SQL queries for time ranges and removed `loadOpenCodeDailySnapshot`. That approach assumed session `updatedAt` could proxy for message timing, but cumulative session totals cannot be correctly time-bounded in memory. This fix reverses that decision for OpenCode.

## Chosen Approach: Daily-Bucket Pre-Load

**At refresh/panel-open time** — load daily-bucketed message tokens alongside the cumulative snapshot. One extra SQL query grouping messages by `(session_id, day)` for the last 30 days.

**On time-range change** — aggregate the in-memory daily buckets to produce per-session per-range totals. Zero SQL.

This preserves the rule from the 2026-06-12 spec: SQL only at refresh or manual refresh. No SQL triggers from any selection change.

```
SQL boundary:
  refreshAll() → loadCumulativeSnapshot() + loadDailyBuckets()
                  ^ SQL here only           ^ SQL here only

In-memory:
  derivedData(.today)     → aggregate buckets for day=today
  derivedData(.last7Days) → aggregate buckets for 7 days
  derivedData(.last30Days)→ aggregate buckets for 30 days
  derivedData(.allTime)   → use cumulative snapshot (no buckets)
```

## New Data Model

```swift
struct OpenCodeDailyBucket: Equatable {
    let sessionID: String
    let day: Int          // UTC day number (time_created / 86400000)
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cost: Double
}
```

## New Query

`OpenCodeUsageQuery.loadDailyBuckets(databaseURL:)` → `[OpenCodeDailyBucket]`

```sql
SELECT m.session_id,
       (m.time_created / 86400000) AS day,
       SUM(coalesce(json_extract(m.data, '$.tokens.input'), 0)),
       SUM(coalesce(json_extract(m.data, '$.tokens.output'), 0)),
       SUM(coalesce(json_extract(m.data, '$.tokens.reasoning'), 0)),
       SUM(coalesce(json_extract(m.data, '$.tokens.cache.read'), 0)),
       SUM(coalesce(json_extract(m.data, '$.tokens.cache.write'), 0)),
       SUM(coalesce(json_extract(m.data, '$.cost'), 0))
FROM message m
WHERE json_extract(m.data, '$.role') = 'assistant'
GROUP BY m.session_id, day
ORDER BY m.session_id, day
```

No time-range WHERE clause — the query loads every day that has assistant messages. Used for Today, 7 Days, 30 Days selections. For very large databases, a where-clause limiting to the last 30 days' message time is acceptable but unnecessary at the volumes pulse targets.

## State Changes

`AgentUsageLoadedState` gains:

```swift
struct AgentUsageLoadedState: Equatable {
    let openCodeCumulativeSnapshot: OpenCodeUsageSnapshot  // All Time (session.*)
    let openCodeDailyBuckets: [OpenCodeDailyBucket]        // per-day per-session (message)
    let codexSnapshot: CodexUsageSnapshot
    let refreshGeneration: Int
    let codexDetailCache: [String: CodexSessionDetailState]
}
```

The `openCodeCumulativeSnapshot` also serves as the metadata source for session titles, directories, agent, model info — data that doesn't change per time range.

## Derivation Logic

```swift
func derivedData(for inputSelection: AgentUsageSelection) -> AgentUsageDerivedViewData {
    let selection = reconcile(inputSelection)

    let openCodeSnapshot: OpenCodeUsageSnapshot
    if selection.timeRange == .allTime || selection.source != .openCode {
        // All Time or non-OpenCode source: use cumulative snapshot, filtered in-memory
        openCodeSnapshot = state.openCodeCumulativeSnapshot.filtered(to: selection.timeRange)
    } else {
        // Time-bounded OpenCode: aggregate from daily buckets
        openCodeSnapshot = aggregatedSnapshot(for: selection.timeRange)
    }
    // ... rest unchanged
}

private func aggregatedSnapshot(for range: AgentTimeRange) -> OpenCodeUsageSnapshot {
    let dayRange = dayRange(for: range)
    let grouped = Dictionary(grouping: state.openCodeDailyBuckets) { $0.sessionID }
    let meta = state.openCodeCumulativeSnapshot

    let records: [OpenCodeSessionRecord] = grouped.compactMap { sessionID, buckets in
        let inRange = buckets.filter { $0.day >= dayRange.lowerBound && $0.day < dayRange.upperBound }
        guard inRange.isEmpty == false,
              let m = meta.sessions.first(where: { $0.id == sessionID })
        else { return nil }

        return OpenCodeSessionRecord(
            id: m.id, title: m.title, directory: m.directory,
            agent: m.agent,
            modelProviderID: m.modelProviderID,
            modelID: m.modelID, modelVariant: m.modelVariant,
            inputTokens: inRange.reduce(0) { $0 + $1.inputTokens },
            outputTokens: inRange.reduce(0) { $0 + $1.outputTokens },
            reasoningTokens: inRange.reduce(0) { $0 + $1.reasoningTokens },
            cacheReadTokens: inRange.reduce(0) { $0 + $1.cacheReadTokens },
            cacheWriteTokens: inRange.reduce(0) { $0 + $1.cacheWriteTokens },
            cost: inRange.reduce(0.0) { $0 + $1.cost },
            createdAt: m.createdAt,
            updatedAt: m.updatedAt
        )
    }
    return OpenCodeUsageSnapshot(sessions: records)
}
```

The `dayRange(for:)` helper converts an `AgentTimeRange` into a pair of UTC day numbers, matching the bucketing scheme.

## Data Flow

```
Panel opens / Refresh pressed
  → store.refreshAll()
    → repository.loadOpenCodeCumulativeSnapshot()
    → repository.loadOpenCodeDailyBuckets()
    → repository.loadCodexSnapshot()
    → state ← { cumulativeSnapshot, dailyBuckets, codexSnapshot }

derivedData(for: selection)
  → .allTime     → state.openCodeCumulativeSnapshot (session columns, unfiltered)
  → .today       → aggregatedSnapshot(for: .today) → in-memory bucket sum
  → .last7Days   → aggregatedSnapshot(for: .last7Days) → in-memory bucket sum
  → .last30Days  → aggregatedSnapshot(for: .last30Days) → in-memory bucket sum
  → Codex side   → unchanged, still .filtered(to:)

Time range picker changes → no SQL, just re-derive from existing buckets
Project / session changes  → no SQL, just re-derive from existing state
```

## Single Source of Truth

- **Session columns** (`session.tokens_*`) — SSOT for All Time.
- **Message rows** (`message.data` with `$.time.created` and `$.tokens.*`) — SSOT for daily buckets.
- **Daily buckets** — derived from messages at refresh time, immutable after load.
- **Aggregated snapshots** — derived from buckets on each `derivedData()` call, not stored.

## Performance Analysis

### Refresh-time SQL

| Query | Est. rows | Est. time |
|-------|-----------|-----------|
| `SELECT * FROM session` | ~200 | ~1ms |
| `SELECT SUM(...) GROUP BY session_id, day FROM message` | ~5K buckets | ~50-150ms |
| `SELECT * FROM threads` (Codex) | ~50 | ~1ms |

Total refresh: ~50-200ms, happening once on panel open and on manual refresh.

### Range-change aggregation

- Filter 5K buckets by day range → ~50-200 items kept
- Group by session_id (~10-50 groups)
- Sum token fields per group → **<1ms**
- Zero SQL

### Memory impact

- Cumulative snapshot: ~200 sessions × ~200 bytes ≈ 40KB
- Daily buckets: ~5K rows × ~64 bytes ≈ 320KB
- Codex snapshot: ~50 threads × ~100 bytes ≈ 5KB
- **Total: <500KB** — negligible for a desktop app

## Edge Cases

### Session with messages outside daily bucket range

If a session has messages within the last 30 days (appears in buckets) but the user selects Today, only today's messages for that session are included. Correct.

### No messages in selected range

`aggregatedSnapshot` returns an empty `OpenCodeUsageSnapshot`. The UI shows 0 tokens for all metrics. Correct behavior — same as current code when no sessions match the range.

### Bucket day/hour boundary

Day computation uses `m.time_created / 86400000` (millisecond epoch / ms-per-day), a UTC-day number. The `AgentTimeRange.contains()` uses `Calendar.current` which is local time. This means a message at 11 PM EST (which is 4 AM UTC next day) could be in a different UTC-day bucket than local Today. This is a pre-existing edge case that affects both the old and new approaches equally, and is not introduced by this fix.

### Deleted sessions / messages

If a message is deleted (its session still exists), the bucket won't include it. If a session is deleted entirely, its bucket data remains in memory until next refresh but won't have matching metadata, so `aggregatedSnapshot` filters it out via `meta.sessions.first(where:)`. Correct — no stale data shown.

### All source mode (OpenCode + Codex combined)

All mode uses `AgentUsageSummary.merge()` of OpenCode and Codex summaries. The OpenCode summary comes from `aggregatedSnapshot(for:)` if time-bounded, or the cumulative snapshot if All Time. Codex still uses `filtered(to:)`. This asymmetry is acceptable because Codex doesn't track cache hits, and its per-session `tokensUsed` inflation is orders of magnitude smaller.

## Code Changes Summary

### New files

**`Managers/OpenCodeDailyBucket.swift`** — `OpenCodeDailyBucket` struct, `loadDailyBuckets()` query method added to `OpenCodeUsageQuery`.

### Changed files

**`Managers/AgentUsageViewData.swift`** — `AgentUsageLoadedState` gains `openCodeDailyBuckets: [OpenCodeDailyBucket]`.

**`Managers/AgentUsageStore.swift`** —
- `refreshAll()` loads both cumulative and bucket data
- `derivedData()` dispatches to `aggregatedSnapshot(for:)` for time-bounded OpenCode ranges
- `dayRange(for:)` helper added to store
- No new public methods (no `refreshTimeRange`)

**`Managers/AgentUsageRepository.swift`** — Add `loadOpenCodeDailyBuckets()` to protocol and impl.

**`Managers/OpenCodeUsageStore.swift`** — Add `loadDailyBuckets(databaseURL:)` static method.

**`Managers/OpenCodeUsageModels.swift`** — No changes (buckets are separate).

**`Views/AgentUsageView.swift`** — No view-layer changes needed (no `.onChange` for time range).

**`Managers/AgentUsageRepository.swift`** — No changes to repository API signature (buckets loaded alongside cumulative snapshot, not as a separate public path).

### Unchanged

- `OpenCodeSessionRecord` — shape unchanged
- `OpenCodeUsageSnapshot` — shape unchanged, `filtered(to:)` still exists but no longer called for OpenCode time-bounded paths
- `CodexUsageSnapshot`, `CodexSessionRecord` — completely untouched
- `AgentUsageView` — no onChange handlers or new wiring
- `AgentUsageDerivedViewData` — shape unchanged

## Testing

### New: `OpenCodeDailyBucket` tests in `OpenCodeUsageStoreTests`

- Verify `loadDailyBuckets` returns expected number of rows
- Verify each bucket's session_id maps to an existing session
- Verify token sums match known message data for a test database

### New: `aggregatedSnapshot` behavior in `AgentUsageStoreTests`

- Verify Today returns only today's message tokens, not cumulative
- Verify 7 Days returns 7 days of data
- Verify All Time uses cumulative snapshot (unchanged)
- Verify empty range returns empty snapshot
- Verify metadata (title, directory, model) matches cumulative source

### Updated: existing `derivedData` tests

- Verify no `.filtered(to:)` is called on the OpenCode snapshot for bounded ranges
- Verify merged All mode still works (OpenCode from buckets + Codex from filtered)

### Integration verification

Build, open Agent panel, select Today:
1. `sqlite3` verify: `tokens_total` matches raw message SUM for today
2. Switch between all four time ranges — no SQL executed, values update instantly
3. Refresh → new SQL, state updates
