# Codex Agent Usage Support — Design Spec

**Date:** 2026-06-09
**Status:** Approved

## Goal

Add Codex CLI as a second data source alongside OpenCode in the Agent Usage tab, with source-specific features (subagent tracking, goal/budget tracking, reasoning effort).

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Data presentation | Separate sources with source picker | Keeps schemas clean, avoids fat optional models |
| Architecture | Enum-routed `AgentUsageStore` | Avoids SwiftUI type-erasure complexity, easy injection |
| Settings toggle | Single "Agent Usage" toggle | Both sources controlled together; auto-discovered |
| Codex-specific features | Subagents, goals, reasoning effort | User-selected; git context excluded |

## Data Models

### Shared types (renamed from OpenCode- prefixed)

- `AgentTimeRange` — `.allTime`, `.today`, `.last7Days`, `.last30Days`
- `AgentScope` — `.allProjects`, `.project(directory:)`, `.session(projectDirectory:sessionID:)`
- `AgentUsageSummary` — `totalTokens: Int`, `inputTokens: Int?`, `outputTokens: Int?`, `reasoningTokens: Int?`, `cacheReadTokens: Int?`, `cacheWriteTokens: Int?`, `sessionsCount: Int`, `cost: Double?`, `lastUpdated: Date?`
  - Optional fields are nil for Codex (which only has `tokens_used` total), populated for OpenCode

### OpenCode-specific (existing, unchanged)

- `OpenCodeSessionRecord`, `OpenCodeUsageSnapshot`, `OpenCodeProjectOption`, `OpenCodeSessionOption`, `OpenCodeModelBreakdown`

### Codex-specific (new)

- `CodexSessionRecord` — `id`, `title`, `cwd`, `model`, `modelProvider`, `tokensUsed`, `reasoningEffort`, `threadSource`, `agentNickname`, `agentRole`, `createdAt`, `updatedAt`
- `CodexUsageSnapshot` — sorted array of `CodexSessionRecord`, same filtering/grouping methods as OpenCode snapshot
- `CodexProjectOption` — groups by `cwd`, with `AgentUsageSummary`
- `CodexSessionOption` — per-session, includes model display name and reasoning effort
- `CodexModelBreakdown` — groups by `model + modelProvider`, with `AgentUsageSummary`
- `CodexSubagentEdge` — `parentThreadID`, `childThreadID`, `status`
- `CodexGoal` — `threadID`, `goalID`, `objective`, `status`, `tokenBudget`, `tokensUsed`

## Store Architecture

### `AgentSource` enum

```swift
enum AgentSource: String, CaseIterable {
    case openCode
    case codex
}
```

### `AgentUsageStore: ObservableObject`

```swift
class AgentUsageStore: ObservableObject {
    @Published var selectedSource: AgentSource = .openCode
    @Published var openCodeSnapshot: OpenCodeUsageSnapshot
    @Published var codexSnapshot: CodexUsageSnapshot
    @Published var isLoading: Bool
    @Published var isRefreshing: Bool
    @Published var lastError: AgentLoadError?
    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL
}
```

- `refresh()` / `refreshIfNeeded()` — only loads the currently selected source
- Source switching triggers a refresh if the new source hasn't loaded yet
- Each source's SQL query logic lives in its own file as pure functions

### DB path detection

- **OpenCode**: unchanged (existing `candidateDatabaseURLs` logic)
- **Codex**: checks `CODEX_DB_PATH` env var first, then `~/.codex/state_5.sqlite`

### Source availability

At init, both DB paths are probed. Only sources with an existing DB file are offered in the source picker. If only one source exists, the picker is hidden and a single badge is shown (like the current "OpenCode" badge).

## SQLite Queries

### OpenCode (unchanged)

```sql
SELECT id, title, directory, coalesce(agent, ''),
       coalesce(json_extract(model, '$.providerID'), ''),
       coalesce(json_extract(model, '$.id'), ''),
       nullif(json_extract(model, '$.variant'), ''),
       coalesce(tokens_input, 0), coalesce(tokens_output, 0),
       coalesce(tokens_reasoning, 0), coalesce(tokens_cache_read, 0),
       coalesce(tokens_cache_write, 0), coalesce(cost, 0),
       time_created, time_updated
FROM session
ORDER BY time_updated DESC
```

### Codex — threads (main query)

```sql
SELECT id, title, cwd, model, model_provider, tokens_used,
       reasoning_effort, thread_source, agent_nickname, agent_role,
       created_at_ms, updated_at_ms
FROM threads
WHERE archived = 0 OR archived IS NULL
ORDER BY updated_at_ms DESC
```

### Codex — subagent edges (lazy, loaded when viewing a session)

```sql
SELECT parent_thread_id, child_thread_id, status
FROM thread_spawn_edges
WHERE parent_thread_id = ? OR child_thread_id = ?
```

### Codex — goals (lazy, loaded when viewing a session)

```sql
SELECT thread_id, goal_id, objective, status, token_budget, tokens_used
FROM thread_goals
WHERE thread_id = ?
```

All queries use read-only + immutable URI mode, same as the existing OpenCode query.

## UI Changes

### Source picker

At the top of `AgentUsageView`, replace the current "OpenCode" capsule badge with two capsule-style toggle buttons: `[OpenCode] [Codex]`. Active source is highlighted. Persisted via `@AppStorage("agentUsageSelectedSource")`.

The picker only shows sources that have a database file found at launch. If only one source exists, auto-selects and the picker is hidden (just shows a single badge like today).

### Shared UI (both sources)

- **Time range selector** — same 4 options
- **Project selector** — `SearchableSelectorView`, groups by `cwd`/`directory`
- **Session selector** — appears when a project is selected
- **Metric cards** — Total Tokens always shown; Input/Output/Reasoning/Cache cards shown only when source provides them
- **Model breakdown** — shown for non-session scopes, groups by model name
- **Context section** — adapts per source and scope

### Codex-specific UI

**Reasoning effort pill:** Shown in session detail context row, e.g. `"Reasoning: high"`. Also shown as a colored dot next to each session in the session selector.

**Subagent section** (session scope only): When a session has subagents, show a collapsible "Subagents" section:
- Count: `"3 subagents"`
- Expandable list: nickname, role, model, tokens_used
- e.g. `"Bohr (worker) — gpt-5.4-mini — 1.2M tokens"`

**Goals section** (session scope only): When a session has goals, show a "Goals" section:
- Each goal: objective, status badge (active=green, paused=yellow, budget_limited=red, complete=gray)
- Token budget progress bar: tokens_used / token_budget

### Settings

No changes to the existing Agent Usage toggle. Source discovery is automatic.

## New Files

| File | Purpose |
|------|---------|
| `Managers/CodexUsageModels.swift` | Codex session record, snapshot, project/session options, model breakdown, subagent edge, goal |
| `Managers/CodexUsageQuery.swift` | Pure functions for Codex SQLite queries (threads, edges, goals) |
| `Views/CodexSessionDetailView.swift` | Subagent + goals sections for Codex session scope |
| `Views/AgentSourcePicker.swift` | Source toggle capsule buttons |

## Modified Files

| File | Changes |
|------|---------|
| `Managers/OpenCodeUsageModels.swift` | Rename `OpenCodeTimeRange` → `AgentTimeRange`, `OpenCodeScope` → `AgentScope`; add `AgentUsageSummary` with optional fields |
| `Managers/OpenCodeUsageStore.swift` | Refactor into `AgentUsageStore` with enum routing; OpenCode loading becomes one path |
| `Views/AgentUsageView.swift` | Add source picker, conditional metric cards, route to Codex-specific sections |
| `App/AppDelegate.swift` | Replace `openCodeUsageStore` with `agentUsageStore`; update injection and refresh calls |
| `Views/PopoverView.swift` | Update `@EnvironmentObject` type from `OpenCodeUsageStore` to `AgentUsageStore` |

## Out of Scope

- No git context display (user chose not to include)
- No combined/unified totals view
- No per-source settings toggles
- No background polling — same refresh-on-open / refresh-on-demand model
