# All-Source Summary + Source Picker Hit Area Fix

**Goal:** Add an "All" option to the agent source picker that shows combined usage metrics across OpenCode and Codex, and fix the source picker button hit area so the entire capsule segment is tappable.

## Current Behavior

- Source picker shows `[OpenCode] [Codex]` capsule toggle
- Only the text area of each capsule segment is tappable (padding/background area is not)
- Each source shows its own full detail view (summary, project/session selectors, context rows, by model table)

## Changes

### 1. `AgentSource` enum — add `.all`

- Add `case all = "all"` with `displayName = "All"`
- Position it first in `CaseIterable` order: `[All, OpenCode, Codex]`
- `AgentSource.all` is a virtual source — no dedicated database, it merges data from both real sources
- `AgentUsageStore.availableSources` always includes `.all` when 2+ real sources are available

### 2. Source picker hit area fix

- Add `.contentShape(Rectangle())` to each button label in `AgentSourcePicker`
- This makes the entire padded capsule segment tappable, not just the text

### 3. "All" mode UI layout

When `selectedSource == .all`:

- **Header** — same as now (source picker + refresh button + DB path label)
- **Time range selector** — same segmented picker, filters both snapshots
- **Project selector** — merged list of unique directories from both sources, with combined summaries per project. Subtitle shows combined token counts and session counts.
- **Session selector** — hidden in All mode
- **Summary card** — combined metrics:
  - `Total` tokens = sum of both sources' `totalTokens`
  - `Sessions` = sum of both sources' `sessionsCount`
  - `Last Updated` = max of both sources' `lastUpdated`
  - Optional breakdown fields (`inputTokens`, `outputTokens`, etc.) — summed if present in either source, nil if absent in both
- **Context section** — hidden in All mode
- **By Model table** — hidden in All mode
- **CodexSessionDetailView** — hidden in All mode

### 4. All-mode data derivation

- `AgentUsageStore` gains a computed `combinedSummary(for:scope:timeRange:)` method
- At the `AgentUsageView` level, the `summary` computed property returns the combined summary when `selectedSource == .all`
- Project options: union of directories from both snapshots. When a directory appears in both sources, tokens and sessions are summed into one entry.
- `AgentUsageStore.databasePath` returns a combined string for `.all` (e.g. "\(openCode path) + \(codex path)")

### 5. OpenCode / Codex modes — unchanged

Individual source views work exactly as before.

### 6. `@AppStorage` default

`agentUsageSelectedSource` defaults to `"all"` when both sources are available, otherwise falls back to whichever single source exists.

## Files

| File | Action | Change |
|------|--------|--------|
| `pulse/Managers/AgentUsageModels.swift` | Modify | Add `AgentSource.all` case |
| `pulse/Views/AgentSourcePicker.swift` | Modify | Add `.contentShape(Rectangle())` to button labels |
| `pulse/Managers/AgentUsageStore.swift` | Modify | Add combined summary helper, update `availableSources`, update `databasePath` |
| `pulse/Views/AgentUsageView.swift` | Modify | Add All-mode routing, combined project list, conditional hiding of session/context/by-model |

## Constraints

- No external dependencies
- No database changes — All mode derives from existing in-memory snapshots
- No auto-polling — All mode uses data already loaded by `refreshAll()`
