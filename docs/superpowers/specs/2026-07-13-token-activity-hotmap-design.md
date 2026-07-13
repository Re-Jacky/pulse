# Token Activity Hotmap Design

## Goal

Replace the Agent tab's single "Token Trend" chart surface with an all-time-only "Token Activity" surface that defaults to a GitHub-style calendar hotmap while preserving the existing long-term line/area trend chart as an alternate mode.

## User Experience

- The section title becomes "Token Activity".
- A small segmented switcher offers `Activity` and `Trend`.
- `Activity` is the default selected mode and persists with `@AppStorage` so the user choice survives panel reopen.
- The section appears only when the selected range is `All Time`; `Today`, `7 Days`, `30 Days`, and custom date selections hide the chart/map surface.
- `Trend` shows the current all-time line/area chart with the existing compression behavior and bucket-size note.
- Empty behavior stays unchanged: if all-time activity data is empty, the entire section remains hidden.

## Activity Hotmap

- The hotmap uses daily all-time `TokenUsageDataPoint` values from `AgentUsageStore`; no new database queries or refresh behavior are introduced.
- Each day in the displayed calendar year renders as a square cell colored by relative token volume.
- Zero-token buckets remain visible with a muted field color so gaps are readable.
- Intensity is computed against the maximum token count in the displayed data, with several opacity levels over `Color.accentColor`.
- The layout uses a fixed seven-row calendar grid, month labels, and date tooltips, matching the GitHub activity pattern.
- The default displayed year is the current local-calendar year; if it has no activity and older activity exists, fall back to the latest year with activity.

## Architecture

- Keep `TokenUsageDataPoint` unchanged.
- Add `activityCalendarData` to `AgentUsageDerivedViewData` so the calendar map can use uncompressed daily all-time totals while the trend chart keeps the existing compressed `tokenFlowData`.
- Refactor `AgentUsageFlowChartView` into a reusable chart container with two internal renderers:
  - `AgentUsageActivityHotmapView`
  - `AgentUsageTrendChartView`
- Update the call site in `AgentUsageView` to render the section only for all-time selections and pass both `data.tokenFlowData` and `data.activityCalendarData`.
- Use existing semantic colors from `Colors.swift` and avoid new hard-coded light/dark theme values.

## Edge Cases

- Non-all-time selections hide the Token Activity section even when the summary and detail cards are filtered by that range.
- All-time trend data may still be bucketed to about 30 points; only the hotmap requires daily uncompressed data.
- Very sparse years should still show inactive cells so the user can distinguish "no activity" from "missing chart".

## Verification

- Build the app with `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`.
- Run the test suite with `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`.
- Manually inspect the Agent tab behavior where possible: default Activity mode, persisted switcher state, and unchanged Trend mode.
