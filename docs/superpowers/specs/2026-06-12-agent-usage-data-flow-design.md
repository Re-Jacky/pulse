# Agent Usage Data Flow Refactor

**Date:** 2026-06-12
**Status:** Ready for Review

## Goal

Refactor Agent Usage so that:

- general agent usage SQL only runs on panel open or manual refresh
- Codex session detail SQL is the only lazy path, and only for session-specific detail not shown in `All`
- loaded data is owned at the top layer as the single source of truth
- all rendering reads derived in-memory data rather than triggering new database work
- all visible sections for a given selection are derived from the same loaded dataset for accuracy and consistency

## Current Problems

The current implementation already loads top-level snapshots from `AppDelegate.openPanel()`, but the data flow is still split across store and view layers in ways that weaken consistency:

- `AgentUsageView` triggers extra store load paths on appearance and selection changes
- OpenCode has a second SQL path for time-range-specific daily data via `loadOpenCodeDailySnapshot`
- Codex session detail is stored as flat top-level fields rather than per-thread cached state
- `AgentUsageView` computes scope filtering, summary selection, project/session options, model breakdowns, provider breakdowns, and token flow directly inside the view
- selection reconciliation is spread across view lifecycle hooks instead of being centralized

This means the UI is not fully data-driven from one canonical loaded state, and it makes it too easy for different sections to render from different intermediate calculations.

## Chosen Approach

Use a three-layer structure:

1. Query / repository layer
2. Store / state ownership layer
3. Derived view-data layer

This keeps SQLite access isolated, keeps loaded state centralized, and keeps presentation data derived from memory instead of recomputing business logic in SwiftUI views.

## Non-Goals

- No background polling
- No new data sources
- No change to the existing Agent Usage feature toggle behavior
- No attempt to build a fully indexed analytics engine
- No change to the existing panel open behavior beyond tightening when data loads

## Loading Rules

### General usage data

General OpenCode and Codex snapshot data must load only when:

- the panel opens and Agent Usage is enabled
- the user presses `Refresh`

General usage data must not load when:

- `AgentUsageView` appears
- the selected source changes
- the selected time range changes
- the selected project changes
- the selected session changes
- the model grouping mode changes

### Codex session detail data

Codex session detail data includes:

- `thread_spawn_edges`
- `thread_goals`

This data may load lazily, but only when:

- the selected source is `Codex`
- the selected scope is a specific Codex session
- the detail has not already been loaded for the current refresh generation

This lazy detail cache must be invalidated on any full refresh so detail accuracy stays aligned with the top-level snapshot generation.

## Consistency Rule

The consistency model for the feature is:

- all general rendering is based on one loaded in-memory snapshot generation
- all selection-based rendering is derived from that same generation
- Codex session detail is allowed to load later, but once loaded it belongs to the same refresh generation
- manual refresh clears all derived and cached detail state that depends on previous loaded data

The UI must never combine stale detail state from an older refresh generation with newly refreshed top-level snapshots.

## Proposed Structure

## Query Layer

Keep `OpenCodeUsageQuery` and `CodexUsageQuery` as pure SQLite readers.

Their responsibility remains:

- resolve database paths
- open readonly immutable SQLite handles
- execute SQL
- map rows into raw domain structs

They must not:

- own UI state
- cache selection-dependent results
- know about view scopes or rendering needs

## Repository Layer

Introduce `AgentUsageRepository` as a thin orchestration layer around the two query types.

### Responsibilities

- load the current OpenCode snapshot
- load the current Codex snapshot
- load Codex detail for one thread
- present one consistent API to the store

### Proposed API

```swift
struct AgentUsageRepository {
    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?

    func loadOpenCodeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail
}
```

`CodexSessionDetail` should be a new raw detail struct:

```swift
struct CodexSessionDetail: Equatable {
    let threadID: String
    let edges: [CodexSubagentEdge]
    let goals: [CodexGoal]
}
```

The repository is intentionally thin. Its job is to isolate query wiring, not to hold state.

## Store Layer

`AgentUsageStore` remains the only mutable owner of Agent Usage state.

### Responsibilities

- own raw loaded datasets
- own refresh lifecycle state
- own source availability
- own refresh generation
- own Codex detail cache
- centralize selection reconciliation
- produce derived view data from in-memory state

### Proposed stored state

```swift
final class AgentUsageStore: ObservableObject {
    @Published private(set) var state: AgentUsageLoadedState
    @Published private(set) var isLoading: Bool
    @Published private(set) var isRefreshing: Bool
    @Published private(set) var lastError: LoadError?

    let availableSources: [AgentSource]
    let repository: AgentUsageRepository

    func refreshAll()
    func derivedData(for selection: AgentUsageSelection) -> AgentUsageDerivedViewData
    func codexDetail(for threadID: String) -> CodexSessionDetailState
    func ensureCodexDetailLoaded(for threadID: String)
}
```

### Loaded state

```swift
struct AgentUsageLoadedState: Equatable {
    let openCodeSnapshot: OpenCodeUsageSnapshot
    let codexSnapshot: CodexUsageSnapshot
    let refreshGeneration: Int
    let codexDetailCache: [String: CodexSessionDetailState]
}
```

### Codex detail cache state

```swift
enum CodexSessionDetailState: Equatable {
    case idle
    case loading
    case loaded(CodexSessionDetail)
    case failed
}
```

The store should clear `codexDetailCache` whenever `refreshAll()` succeeds or when a refresh begins, so cached detail cannot survive across snapshot generations.

The store should no longer treat `selectedSource` as mutable loading control state. Source, time range, project, session, and grouping are selection inputs owned outside the raw loaded-state container and passed into derivation explicitly.

## Selection Model

Introduce one explicit selection struct instead of reconstructing selection from multiple unrelated view computations.

```swift
struct AgentUsageSelection: Equatable {
    let source: AgentSource
    let timeRange: AgentTimeRange
    let projectDirectory: String?
    let sessionID: String?
    let modelGroupBy: AgentModelGroupBy
}
```

With:

```swift
enum AgentModelGroupBy: String, Equatable {
    case provider
    case model
}
```

The store should expose a reconciliation helper:

```swift
func reconcile(_ selection: AgentUsageSelection) -> AgentUsageSelection
```

This helper is responsible for:

- dropping a missing project after refresh
- dropping a missing session after refresh
- forcing `sessionID = nil` when source is `All`
- forcing `sessionID = nil` when project is `nil`
- clearing invalid Codex session selection if the session is filtered out by current time range

This moves selection consistency into one place.

## Derived View-Data Layer

Introduce a dedicated derived view-data model so SwiftUI renders from a single computed output.

### Proposed shape

```swift
struct AgentUsageDerivedViewData: Equatable {
    let selection: AgentUsageSelection
    let scope: AgentScope
    let summary: AgentUsageSummary
    let projectOptions: [SearchableSelectorOption]
    let sessionOptions: [SearchableSelectorOption]
    let tokenFlowData: [TokenUsageDataPoint]
    let usageMetrics: [AgentUsageMetricCard]
    let summaryPills: [AgentUsageSummaryPill]
    let contextRows: [AgentUsageDetailRow]
    let providerBreakdown: [ProviderBreakdown]
    let modelBreakdownRows: [AgentUsageDetailRow]
    let selectedOpenCodeSession: OpenCodeSessionRecord?
    let selectedCodexSession: CodexSessionRecord?
    let codexDetailThreadID: String?
    let isSessionScope: Bool
    let showsByModel: Bool
    let showsTokenFlow: Bool
}
```

Support rows can be lightweight UI-ready structs:

```swift
struct AgentUsageMetricCard: Equatable, Identifiable
struct AgentUsageSummaryPill: Equatable, Identifiable
struct AgentUsageDetailRow: Equatable, Identifiable
```

The important rule is not the exact struct names. The important rule is that view rendering is fed by one derived output rather than many parallel computed properties.

## Data Derivation Rules

### Time range handling

Remove `openCodeDailySnapshot` and `loadOpenCodeDailySnapshot`.

All time-range filtering must happen from already loaded snapshots in memory:

- `OpenCodeUsageSnapshot.filtered(to:)`
- `CodexUsageSnapshot.filtered(to:)`

No time-range change should ever trigger SQL.

### All source mode

`All` mode remains an in-memory merge:

- filtered OpenCode snapshot
- filtered Codex snapshot

`AgentUsageSummary.merge()` remains valid for summary totals.

The derived layer is responsible for:

- merged summary
- unioned project list
- token flow chart data
- hiding session selector
- hiding context sections that are source-specific
- hiding provider/model sections when unsupported

### Project and session options

Project and session options should be computed only in the derived layer, not piecemeal in the view.

This includes:

- sorting
- subtitle formatting
- source-specific filtering such as excluding Codex subagents from project and session summaries

### Context rows

The view should no longer build context content with large `switch` statements over raw snapshots.

Instead, the derived layer should emit the exact rows to render for the current scope:

- all projects context
- project context
- session context

### Token flow chart

`AgentUsageFlowChartView` should receive only precomputed chart data.

Bucket generation remains in memory from already loaded sessions.

No chart path should require new SQL.

## View Responsibilities After Refactor

`AgentUsageView` should become a thin rendering layer.

### Allowed responsibilities

- persist local UI selection with `@AppStorage`
- turn persisted values into `AgentUsageSelection`
- ask store for reconciled selection
- read one `AgentUsageDerivedViewData`
- call `refreshAll()` when the user presses `Refresh`
- request lazy Codex detail when a Codex session becomes active

### Responsibilities to remove from the view

- direct summary composition
- direct time-range filtering logic
- direct token flow bucket creation
- direct project/session option assembly
- direct model/provider breakdown calculation
- direct context-row composition from raw snapshots
- any SQL-triggering behavior on view appearance or selection change

## Codex Detail Rendering

`CodexSessionDetailView` should stop reading flat arrays from the store.

Instead it should receive a single detail state:

```swift
CodexSessionDetailView(
    session: CodexSessionRecord,
    detailState: CodexSessionDetailState
)
```

Behavior:

- `idle` or `loading`: show lightweight progress state
- `loaded`: render subagents and goals
- `failed`: show safe fallback text

This makes the detail view data-driven and removes hidden coupling to global mutable arrays.

## AppDelegate Behavior

`AppDelegate.openPanel()` remains the top-level general-load trigger.

Preferred behavior:

- if Agent Usage is enabled, call one store refresh method for general data
- do not trigger additional view-driven refreshes for initial panel state

This preserves the current product behavior while making the load boundary explicit.

## Error Handling

Errors should stay source-aware for top-level loading:

- OpenCode load failure
- Codex load failure

Codex detail load failures should be scoped to the selected session detail state instead of poisoning the entire Agent Usage view.

This means:

- top-level snapshot errors still control the main unavailable state
- session detail errors only affect the detail section

## Testing Plan

Add or update tests around the refactor.

### Store behavior

- refresh loads general snapshots exactly once per refresh call
- selection changes do not trigger repository loads
- successful refresh clears old Codex detail cache
- failed Codex detail load only affects that thread detail state

### Selection reconciliation

- invalid project resets to all projects
- invalid session resets to project scope
- `All` source never exposes session scope

### Derived data

- summary, project options, session options, model breakdown, provider breakdown, and token flow all reflect the same filtered scope
- OpenCode time-range changes use in-memory filtering only
- Codex subagents stay excluded from project/session summary scopes where intended

### Lazy detail loading

- selecting a Codex session triggers one detail load
- reselecting the same session within the same refresh generation does not reload detail
- manual refresh invalidates prior detail cache and allows a fresh load

## Migration Steps

1. Add repository and new loaded-state / selection / derived-data models.
2. Move Codex detail into a per-thread cached state model.
3. Remove `openCodeDailySnapshot` and its store/view call sites.
4. Move derivation logic out of `AgentUsageView` into store-owned helpers.
5. Simplify `CodexSessionDetailView` to consume detail state directly.
6. Update tests to target the new flow.
7. Verify panel-open refresh behavior still works and no selection change causes SQL.

## Risks

### Risk: too much derived work on every render

Mitigation:

- derive once per selection change in store-facing helpers
- keep the raw snapshots simple
- add tests around stable outputs

### Risk: stale selection after refresh

Mitigation:

- centralize reconciliation in store
- always reconcile after refresh and after selection changes

### Risk: lazy detail out of sync with refreshed snapshot

Mitigation:

- clear all detail cache on refresh generation change
- store detail state keyed by `threadID` within the current generation only

## Decision Summary

The refactor will treat Agent Usage as a data-driven screen backed by one top-level in-memory state owner:

- SQL for general data runs only on panel open or manual refresh
- SQL for Codex session detail runs lazily only when needed
- all rendered sections consume derived in-memory data
- consistency is enforced by refresh-generation ownership and centralized selection reconciliation
