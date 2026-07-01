# Agent Usage Date Picker Design

Date: 2026-07-01
Repo: `/Users/zyao/Desktop/pulse`

## Goal

Replace the Agent usage view's fixed range selector with a compact, polished date picker trigger that supports:

- Preset shortcuts: `All Time`, `Today`, `7 Days`, `30 Days`
- A single explicit day selection
- An explicit inclusive date range selection

The feature must only change how the target day or date range is selected. It must not change how agent usage data is fetched, refreshed, or loaded from disk.

## Constraints

- The app is a native macOS menu bar app; the picker should feel native and compact in the existing panel.
- The current refresh behavior stays unchanged.
- SQL access must remain in the existing refresh/load path only.
- Range switching must remain purely in-memory.
- Day bucketing must remain local-calendar based, not raw 86400-second window math.

## Current Architecture Summary

The current implementation uses a fixed `AgentTimeRange` enum in `pulse/Managers/AgentUsageModels.swift` and threads that enum through:

- `AgentUsageSelection` in `pulse/Managers/AgentUsageViewData.swift`
- day range helpers in `pulse/Managers/AgentUsageModels.swift`
- in-memory derivation paths in `pulse/Managers/AgentUsageStore.swift`
- the Agent view controls in `pulse/Views/AgentUsageView.swift`

The current architecture intentionally loads source data during refresh and then performs range changes in memory against precomputed snapshots and day buckets. That performance characteristic must be preserved.

## Recommended Approach

Use a compact summary button in the Agent view that opens a custom native-styled popover. The popover contains:

- Shortcut chips for `All Time`, `Today`, `7 Days`, `30 Days`
- A mode switch between `Single Day` and `Range`
- A calendar-based selection area
- Apply behavior so the dashboard updates only after the user confirms the selection

This is preferred over an always-visible inline control because the Agent panel is space-constrained and should remain visually calm. It is preferred over a fully custom calendar because the feature's value is in a polished interaction, not in owning an entire calendar implementation.

## Interaction Design

### Trigger

The existing fixed range selector is replaced with a single compact trigger button. The trigger label reflects the active selection:

- `All Time`
- `Today`
- a single explicit day such as `Jul 1, 2026`
- a custom range such as `Jun 10 - Jul 1`

### Popover Content

The popover contains, from top to bottom:

1. Shortcut chips for the preset selections
2. A segmented mode switch: `Single Day` or `Range`
3. Native-feeling date selection controls for the chosen mode
4. Confirmation controls, including `Apply`

### Selection Rules

- `All Time` clears any explicit date selection and acts as a no-filter state
- `Today` resolves to the current local calendar day
- `7 Days` and `30 Days` remain shortcuts above the calendar rather than first-class visible modes
- `Single Day` resolves to an inclusive one-day interval
- `Range` resolves to an inclusive start/end day interval
- If end date is earlier than start date, normalize by swapping them

## Data Model Changes

Replace the enum-only time selection with a richer selection model that can represent:

- preset selections
- a single explicit day
- an explicit day range

The model should normalize all non-`All Time` selections into a local-calendar day interval before any derivation logic runs.

Suggested shape:

- `preset(allTime | today | last7Days | last30Days)`
- `singleDay(dayIdentifier)`
- `dayRange(startDayIdentifier, endDayIdentifier)`

The exact type names can follow repo conventions, but the important behavior is:

- preserve presets for concise UI and migration compatibility
- support arbitrary explicit dates
- normalize to day identifiers derived from `Calendar.startOfDay`

## Data Flow Requirements

The fetch and refresh pipeline does not change.

Unchanged behavior:

- `PopoverView` still refreshes when the Agent tab becomes visible
- manual `Refresh` still triggers the same refresh path
- stores still load data into snapshots and daily buckets during refresh only

Changed behavior:

- view derivation now consumes a resolved day interval produced by the date picker selection model instead of a fixed `AgentTimeRange`

This preserves the existing rule that date changes operate only on already-loaded state.

## Store And Derivation Changes

Update derivation helpers so they consume a resolved day interval rather than a fixed preset enum.

The main affected logic includes:

- day interval resolution helper(s)
- in-memory bucket filtering
- token flow derivation
- session filtering
- project summary filtering
- model breakdown filtering

`All Time` remains a special case representing no interval filter.

Rolling shortcuts like `7 Days` and `30 Days` should resolve to local-calendar intervals at derivation time, relative to the current local day, without changing refresh behavior.

## UI Component Boundaries

Keep the picker UI isolated from the main Agent view by introducing dedicated view components, for example:

- a compact summary trigger view
- a popover content view

The exact names can vary, but the goal is to avoid pushing calendar interaction state and rendering details directly into `AgentUsageView`.

## Persistence And Migration

The current range selection is persisted via app storage. The new model should remain persistable through app storage-compatible values.

Migration requirements:

- Existing persisted presets should map cleanly into the new model
- Users with stored `today`, `last_7_days`, `last_30_days`, or `all_time` selections should retain equivalent behavior after upgrade
- New explicit day/range selections should persist without affecting refresh logic

## Empty States And UX Edge Cases

- If the selected day or range has no data, keep the current empty-state behavior and show the explicit label for the chosen selection
- If only one endpoint is changed in range mode before apply, keep the draft state local to the picker until confirmation
- The summary label should always make it obvious whether the view is showing a preset, a single day, or a custom range

## Testing Plan

Focus tests on date-resolution and derivation behavior, not on data-fetch changes.

Required coverage:

- preset selections still resolve correctly
- single-day selection resolves to exactly one local day
- custom range selection is inclusive on both ends
- reversed start/end dates normalize correctly
- `All Time` bypasses filtering
- changing the date selection does not trigger refresh/load behavior
- existing summaries, counts, and token flow continue to derive only from loaded buckets

UI verification should confirm:

- the trigger label updates correctly for presets, single day, and range
- the popover remains compact and usable within the menu bar panel
- shortcut chips and calendar selection work together without forcing immediate dashboard churn before apply

## Out Of Scope

- Any change to how OpenCode or Codex data is discovered or loaded
- Any change to refresh timing
- Any new scheduled refresh behavior
- Any database query changes driven by date selection
- A fully custom calendar implementation unless native options prove insufficient during implementation

## Success Criteria

The feature is successful if:

- users can choose `All Time`, `Today`, `7 Days`, `30 Days`, one explicit day, or an explicit range from a polished compact picker
- the Agent panel remains compact and native-feeling
- all date changes are handled via in-memory filtering on already-loaded data
- no data fetch behavior changes
- local-calendar day semantics remain correct for user-facing day ranges
