# Design: Requests + Cache Hit Rate Metrics

**Date**: 2026-06-26
**Status**: Approved

## Summary

Add two new metrics to the Agent Usage tab:
1. **Requests** — count of LLM API calls, shown as a metric card
2. **Cache Hit Rate** — `cacheReadTokens / inputTokens`, shown as a summary pill (percentage)

Both leverage existing data columns; no schema changes to the underlying databases.

## Data Model Changes

### Structs

| Struct | Change |
|--------|--------|
| `OpenCodeDailyBucket` | Add `requestCount: Int` (default 0) |
| `CodexDailyBucket` | Add `requestCount: Int` (default 0) |
| `AgentUsageSummary` | Add `requestCount: Int` (default 0) |
| `OpenCodeSessionRecord` | Add `requestCount: Int` (default 0) |

`CodexSessionRecord` — no change; request count flows from daily bucket roll-up only.

### Query Changes

**OpenCode `loadDailyBuckets`**: Each `role='assistant'` message row already iterated — increment `requestCount` per row per day bucket.

**OpenCode snapshot SQL**: Add subquery:
```sql
(SELECT COUNT(*) FROM message WHERE session_id = s.id
 AND json_extract(data, '$.role') = 'assistant') AS request_count
```

**Codex `accumulateDailyBuckets`**: Each `token_count` JSONL event already iterated — increment `requestCount` per event per day bucket.

### Aggregation

- `requestCount` sums through bucket-to-summary roll-up identically to token fields
- `AgentUsageSummary.merge()`: `merged.requestCount = a.requestCount + b.requestCount`
- Cache hit rate: **not stored** — derived at view time as `cacheReadTokens / inputTokens`

## UI Changes

### Metric Cards (2-column grid)

Add **"Requests"** card: formatted integer (e.g. "1,247"), placed after existing cards (Total, Input, Output, Cache Read).

### Summary Pills (horizontal scroll)

Add **"Hit Rate"** pill: formatted percentage (e.g. "68%"), placed alongside Reasoning/Cache Write/Sessions/Last Updated/Cost.

Hidden when `cacheReadTokens` is nil or `inputTokens` is nil/zero.

## Edge Cases

| Case | Behavior |
|------|----------|
| No cache data (nil cacheReadTokens) | Hit Rate pill hidden (same as Cache Read card today) |
| Zero inputTokens | Hit Rate pill hidden (avoids div-by-zero) |
| Codex lacks cacheWriteTokens/cost | No impact; cacheReadTokens and inputTokens are parsed from JSONL |
| All source merge | Request counts sum; hit rate derives from merged cacheRead/input |
| Codex All-time (no buckets) | requestCount = 0; Codex state DB has no per-thread message count column. Codex all-time with daily buckets will roll up from buckets. Codex all-time without buckets (no JSONL transcripts found) will show 0 — acceptable since request count is bucket-sourced for Codex. |

## What Is NOT Changing

- No database schema changes (opencode.db, Codex state DBs)
- No new SQL tables or columns
- No changes to existing token metric cards or pills
- No chart changes (token flow chart unchanged)
