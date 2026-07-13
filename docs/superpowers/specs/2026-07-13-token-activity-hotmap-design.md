# Token Activity Hotmap Design

## Goal

Replace the Agent tab's single "Token Trend" chart surface with a compact chart switcher that defaults to a GitHub-style token activity hotmap while preserving the existing line/area trend chart as an alternate mode.

## User Experience

- The section title becomes "Token Activity".
- A small segmented switcher offers `Activity` and `Trend`.
- `Activity` is the default selected mode and persists with `@AppStorage` so the user choice survives panel reopen.
- `Trend` shows the current line/area chart with the existing behavior and bucket-size note.
- Empty or hidden chart behavior stays unchanged: if `showsTokenFlow` is false or `tokenFlowData` is empty, the entire section remains hidden.

## Activity Hotmap

- The hotmap uses existing `TokenUsageDataPoint` values from `AgentUsageStore`; no new database queries or refresh behavior are introduced.
- Each visible day or aggregated bucket renders as a square cell colored by relative token volume.
- Zero-token buckets remain visible with a muted field color so gaps are readable.
- Intensity is computed against the maximum token count in the displayed data, with several opacity levels over `Color.accentColor`.
- The layout uses a fixed seven-row calendar grid when data is daily, matching the GitHub activity pattern.
- If all-time data is aggregated into multi-day buckets, the same component renders compact sequential cells and shows the existing "Each point combines N days." note.

## Architecture

- Keep `TokenUsageDataPoint` unchanged.
- Refactor `AgentUsageFlowChartView` into a reusable chart container with two internal renderers:
  - `AgentUsageActivityHotmapView`
  - `AgentUsageTrendChartView`
- Keep the call site in `AgentUsageView` simple: pass `data.tokenFlowData` exactly as today.
- Use existing semantic colors from `Colors.swift` and avoid new hard-coded light/dark theme values.

## Edge Cases

- A single-day selection still does not show token flow because the store currently returns no flow data for today/single-day style views.
- All-time ranges may already be bucketed to about 30 points; the hotmap must label this clearly instead of implying exact daily activity.
- Very sparse ranges should still show inactive cells so the user can distinguish "no activity" from "missing chart".

## Verification

- Build the app with `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`.
- Run the test suite with `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`.
- Manually inspect the Agent tab behavior where possible: default Activity mode, persisted switcher state, and unchanged Trend mode.
