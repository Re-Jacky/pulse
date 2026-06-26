# Design: Requests + Cache Hit Rate Metrics

**Date**: 2026-06-26
**Status**: Approved

## Summary

Add two new metrics to the Agent Usage tab:
1. **Requests** — count of LLM API calls, shown as a metric card
2. **Cache Hit Rate** — `cacheReadTokens / inputTokens`, shown as a summary pill (percentage)

Both leverage existing data columns; no schema changes to the underlying databases.

## Single Source of Truth

The existing data flow follows a clear pattern:
- **Daily buckets** are the single query-level source for per-day granular data
- **Session records** for non-allTime ranges are **derived** from buckets via `aggregatedSnapshot` / `aggregatedCodexSnapshot` (summing bucket fields)
- **Session records** for allTime come from a separate `loadSnapshot` query (reads the `session` table directly)
- **`AgentUsageSummary`** is derived from session records via `makeSummary(from:)`
- **View metrics** are derived from the summary

`requestCount` follows this same pattern — it has two natural query-time sources (one per existing query path), and all downstream data is derived from those.

## Data Model Changes

### Structs

| Struct | Change | Rationale |
|--------|--------|-----------|
| `OpenCodeDailyBucket` | Add `requestCount: Int` (default 0) | Populated during `loadDailyBuckets` iteration — each `role='assistant'` message row = 1 request |
| `CodexDailyBucket` | Add `requestCount: Int` (default 0) | Populated during `accumulateDailyBuckets` iteration — each `token_count` JSONL event = 1 request |
| `AgentUsageSummary` | Add `requestCount: Int` (default 0) | Derived from `makeSummary` — sums from session records |
| `OpenCodeSessionRecord` | Add `requestCount: Int` (default 0) | Two sources: (1) allTime `loadSnapshot` SQL COUNT subquery, (2) ranged `aggregatedSnapshot` sums from buckets |

`CodexSessionRecord` — no change; Codex has no per-thread message count in the `threads` table. Codex `requestCount` is computed from daily buckets and injected into the summary at derivation time (see "Codex `requestCount` enrichment" below).

### Query Changes

**OpenCode `loadDailyBuckets`** (line 277–379 of OpenCodeUsageStore.swift): Already iterates each `role='assistant'` message row. Increment `requestCount += 1` per row into each day bucket (same accumulation pattern as existing token fields at line 357–370).

**OpenCode `loadSnapshot`** (line 197–275 of OpenCodeUsageStore.swift): Add COUNT subquery to the SQL:
```sql
(select count(*) from message where message.session_id = session.id
 and json_extract(message.data, '$.role') = 'assistant') as request_count
```
Read `request_count` column into `OpenCodeSessionRecord.requestCount`.

**OpenCode `loadDailySnapshot`** (line 92–195): Same — add `COUNT(*)` or a `COUNT(m.id)` grouped by session. Since this query already joins `message` and groups by `s.id`, adding `COUNT(m.id) as request_count` to the SELECT is sufficient.

**Codex `accumulateDailyBuckets`** (line 327–410 of CodexUsageQuery.swift): Already iterates each `token_count` JSONL event. Increment `requestCount += 1` per event per day bucket (same accumulation pattern as existing token deltas).

### Aggregation (Derived — No New Queries)

**OpenCode path** (all scopes/ranges): `requestCount` flows naturally through `OpenCodeSessionRecord.requestCount` → `makeSummary` → `AgentUsageSummary.requestCount`. No special handling needed.

**Codex path — bucket enrichment**: Since `CodexSessionRecord` does not carry `requestCount` and `makeSummary(from: [CodexSessionRecord])` cannot derive it, the Codex `requestCount` must be computed from daily buckets and injected into the summary at derivation time. This happens in `AgentUsageStore.derivedData(for:)` (line 205–228), where the `baseSummary` is built. After computing `baseSummary`, compute the Codex request count from `state.codexDailyBuckets` (filtered by range/scope) and set `summary.requestCount` accordingly:

1. Filter `state.codexDailyBuckets` by day range (same logic as `aggregatedCodexSnapshot`)
2. Further filter by scope (session ID or project directory match)
3. Sum `bucket.requestCount`
4. Set `baseSummary.requestCount = codexBucketRequestCount` for Codex source; or add to existing OpenCode `requestCount` for All source

This keeps daily buckets as the single source of truth for Codex request count, with no separate query needed.

**`AgentUsageSummary.merge()`** (AgentUsageModels.swift:91–109): Add `requestCount: a.requestCount + b.requestCount`.

**Cache hit rate**: **not stored** — derived at view-derivation time as `cacheReadTokens / inputTokens` when both are non-nil and `inputTokens > 0`.

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
| Codex All-time (no buckets) | requestCount = 0; Codex state DB has no per-thread message count column. Codex all-time with daily buckets will sum from buckets in `derivedData` enrichment. Codex all-time without buckets (no JSONL transcripts found) will show 0. |
| OpenCode allTime | requestCount from `loadSnapshot` COUNT subquery → `OpenCodeSessionRecord` → `makeSummary` |
| Codex requestCount derivation | Always from daily buckets (enriched in `derivedData`), never from `CodexSessionRecord` or `CodexUsageSnapshot.makeSummary` |

## What Is NOT Changing

- No database schema changes (opencode.db, Codex state DBs)
- No new SQL tables or columns
- No changes to existing token metric cards or pills
- No chart changes (token flow chart unchanged)
