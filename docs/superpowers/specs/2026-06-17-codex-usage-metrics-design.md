# Codex Usage Metrics Migration Design

## Goal

Extend Codex usage reporting so the Codex source can show detailed token metrics similar to the OpenCode source while preserving the existing architecture:

- data-driven views only
- no SQL or raw data access in child components
- manager/repository/store/view-data flow remains the same
- ranged Codex usage must not rely on `threads.updated_at_ms`

This migration builds on the existing transcript-based range fix and expands the Codex data model from total-only usage into detailed token usage.

## Current State

Codex currently uses two separate sources:

- SQLite `threads` rows for session metadata
- JSONL transcripts under `~/.codex/sessions` for accurate cross-day ranged usage

The current implementation fixes the cross-day attribution bug by deriving ranged totals from transcript-backed daily buckets, but those buckets only store total token usage. That means Codex can now show accurate ranged totals, but not detailed metrics like input, output, reasoning, or cache read.

OpenCode already follows a stronger pattern:

- metadata and cumulative session data are loaded in managers
- daily buckets are loaded in managers
- `AgentUsageStore` derives ranged snapshots from buckets
- SwiftUI views consume only precomputed data

The Codex migration should follow that same pattern.

## Design Rules

### Source of Truth

Codex usage will use two different sources with clear responsibilities:

- `CodexSessionRecord` loaded from SQLite remains the metadata source
- `CodexDailyBucket` loaded from transcripts becomes the ranged usage source

SQLite remains responsible for:

- thread identity
- title
- cwd
- model
- reasoning effort
- created/updated timestamps
- subagent edges
- goals

Transcripts remain responsible for:

- per-event token usage
- cross-day attribution
- ranged aggregation

### Total Tokens Rule

Codex `totalTokens` must preserve Codex native `total_tokens` from transcript `token_count` events whenever that field exists.

Fallback rule:

- if `total_tokens` exists, use it
- if `total_tokens` is absent, recompute from available fields as a fallback

This rule applies during transcript parsing, bucket aggregation, and ranged snapshot construction.

We do not force Codex into OpenCode’s recomputed total formula when native `total_tokens` is present.

### Detailed Metrics Rule

Detailed Codex summary fields map directly from transcript data:

- `inputTokens` = `input_tokens`
- `outputTokens` = `output_tokens`
- `reasoningTokens` = `reasoning_output_tokens`
- `cacheReadTokens` = `cached_input_tokens`
- `cacheWriteTokens` = `nil` unless a real Codex source is discovered later

No placeholder or inferred cache write value should be introduced.

### Range Rule

For Codex, any time range other than `allTime` must be computed from transcript-derived daily buckets and never from `threads.updated_at_ms`.

This applies to:

- global summaries
- project summaries
- session summaries
- project picker totals
- session picker totals
- model/provider breakdowns
- token flow chart

### Missing Transcript Rule

If a session exists in SQLite but has no transcript-derived usage buckets, it must not silently fall back to `updatedAt` bucketing for ranged views.

For non-`allTime` ranges:

- sessions with no bucket data are excluded from ranged Codex aggregation

For `allTime`:

- session metadata remains visible through the SQLite snapshot

This avoids reintroducing the original misattribution bug.

## Architecture

### Data Layer

Codex should continue to mirror the existing pattern:

1. Query managers load raw persisted data.
2. Repository exposes normalized loading functions.
3. `AgentUsageStore` owns all aggregation and derivation.
4. Views consume only derived display data.

No child view should execute SQL, inspect transcripts, or perform aggregation.

### Models

#### `CodexSessionRecord`

`CodexSessionRecord` remains the metadata model. It does not become a raw event or bucket model.

It should be extended so ranged reconstructed sessions can populate detailed summary fields, either by:

- adding detailed token fields to the session record itself, or
- introducing a parallel ranged session aggregate model used only within Codex aggregation

Recommended approach:

- extend `CodexSessionRecord` with optional detailed token fields

That keeps the pattern closest to OpenCode and avoids creating a second parallel session-display type.

Recommended fields:

- `inputTokens: Int?`
- `outputTokens: Int?`
- `reasoningTokens: Int?`
- `cacheReadTokens: Int?`

`tokensUsed` remains the canonical displayed total for Codex, backed by native `totalTokens`.

#### `CodexDailyBucket`

`CodexDailyBucket` should be expanded from:

- `sessionID`
- `day`
- `tokensUsed`

to:

- `sessionID`
- `day`
- `inputTokens`
- `outputTokens`
- `reasoningTokens`
- `cacheReadTokens`
- `totalTokens`

It should not include cost or cache write at this stage.

### Query Layer

`CodexUsageQuery` continues to own:

- SQLite thread loading
- transcript scanning
- daily bucket creation

Transcript parsing must continue to read:

- `session_meta`
- `turn_context`
- `event_msg` where `payload.type == "token_count"`

For each token event:

- parse native `total_tokens` if present
- parse detailed counters if present
- compute per-event delta from cumulative totals
- group deltas into day buckets

Zero-delta events must still be ignored.

### Repository Layer

`AgentUsageRepository` remains the single bridge between store and query managers.

It should expose:

- `loadCodexSnapshot()`
- `loadCodexDailyBuckets()`
- `loadCodexDetail(threadID:)`

No view or child component should bypass this layer.

### Store Layer

`AgentUsageStore` remains the single data-preparation layer for the agent usage UI.

It should hold:

- `codexSnapshot`
- `codexDailyBuckets`

For `allTime`:

- use the full `codexSnapshot` for current session ordering and metadata presentation

For non-`allTime` ranges:

- derive a reconstructed Codex snapshot from `codexDailyBuckets`
- aggregate detailed counters and total tokens into per-session records

The same reconstructed ranged data must drive:

- summary cards
- summary pills
- project/session options
- provider/model breakdowns
- token flow

That keeps all Codex ranged displays consistent with each other.

## Session Scope Behavior

For Codex session scope in ranged views:

- metadata fields come from the SQLite-backed session record
- usage values come from the selected range’s aggregated bucket totals

That means a selected session can show:

- full title/model/path/createdAt
- but only the chosen range’s input/output/reasoning/cache-read/total usage

This behavior matches the purpose of the range selector and avoids mixing lifetime and ranged usage values.

## UI Impact

The UI layer should require minimal change because it already consumes normalized summary fields through `AgentUsageSummary`.

Once Codex summaries begin populating:

- `inputTokens`
- `outputTokens`
- `reasoningTokens`
- `cacheReadTokens`

the existing cards and pills logic can render them just like OpenCode.

No child component should gain new data-access responsibilities.

## Error Handling

Transcript parsing should remain tolerant:

- malformed lines are skipped
- missing optional fields are treated as absent
- missing `total_tokens` falls back to recomputed totals
- missing transcript files do not crash the Codex source

If transcript-derived bucket data is empty:

- `allTime` still works from SQLite metadata
- ranged Codex usage shows only sessions with valid bucket data

SQLite loading errors and transcript parsing errors should remain contained to the manager/repository/store layer and surfaced through the existing load error path.

## Testing Strategy

Add focused tests that follow the existing agent usage test style.

### Query Tests

Cover:

- transcript parsing preserves native `total_tokens`
- transcript parsing extracts input/output/reasoning/cache-read correctly
- cross-day sessions split into separate daily buckets
- zero-delta events are ignored
- fallback behavior when `total_tokens` is absent
- WAL-backed SQLite snapshot loading still works

### Store Tests

Cover:

- Codex `today` summary uses bucketed detailed fields instead of `updatedAt`
- Codex `7 days` and `30 days` aggregate detailed fields correctly
- project/session/global summaries stay internally consistent
- sessions with no ranged bucket data are excluded from ranged Codex totals
- token flow matches the same bucket totals used by summary cards

### View-Data Tests

Cover:

- Codex summary cards/pills expose detailed fields when available
- Codex session scope keeps metadata while showing range-limited usage

## Scope Boundaries

Included in this migration:

- transcript-backed detailed Codex token metrics
- ranged Codex detailed summaries
- normalized UI exposure through existing store/view-data flow

Explicitly excluded:

- Codex cost calculation
- cache write support without a real source field
- moving SQL or parsing into views
- redesigning the agent usage UI structure

## Recommendation

Use the OpenCode-parallel approach:

- keep SQLite session metadata loading as-is
- expand transcript-derived Codex daily buckets
- perform all ranged aggregation in `AgentUsageStore`
- expose richer `AgentUsageSummary` values to the existing UI

This gives Codex richer metrics without introducing a second architecture or violating the current data-driven boundaries.
