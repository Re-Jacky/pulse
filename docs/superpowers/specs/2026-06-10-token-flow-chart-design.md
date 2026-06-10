# Token Flow Line Chart — Design

## Overview

Add a line chart to the Agent Usage "All" view showing token usage over time. The chart appears as a new card below the existing "Usage" summary card when the source is "All" and a date range other than "Today" is selected.

## Requirements

1. Only shown in "All" source view, when time range ≠ Today
2. Line chart of merged OpenCode + Codex total tokens per time bucket
3. X-axis: daily buckets for 7D/30D; adaptive buckets for All Time
4. No changes to existing models, stores, or other views

## New Types

### `TokenUsageDataPoint` (in `AgentUsageView.swift`)

```swift
struct TokenUsageDataPoint: Identifiable {
    let date: Date       // bucket start
    let totalTokens: Int
    var id: Date { date }
}
```

## Data Pipeline

```
openCodeFilteredSnapshot.sessions  ─┐
                                    ├─ merge by updatedAt → group by date bucket → [TokenUsageDataPoint]
codexFilteredSnapshot.sessions     ─┘
```

- Time range filter already applied by `filtered(to:)`
- Both snapshot arrays are combined into a flat list of `(updatedAt, totalTokens)` pairs
- Pairs are bucketed by date, summing tokens within each bucket
- Zero-token buckets get a data point to keep the line continuous

## Bucketing Logic

| Time Range | Bucket Size |
|------------|-------------|
| `.today`   | N/A (hidden) |
| `.last7Days` | 1 day |
| `.last30Days` | 1 day |
| `.allTime` | `max(1, ceil(totalDays / 30))` |

`totalDays` = calendar days from earliest session's `updatedAt` to `now`.

Buckets are contiguous, stride from `earliest` to `now` by bucket size.

## Chart Rendering

**New file:** `Views/AgentUsageFlowChartView.swift`

- SwiftUI `Chart` with `AreaMark` (gradient fill) + `LineMark` (solid line)
- Interpolation: `.catmullRom` for smooth curves
- Y-axis: compact token labels (1.5K, 12M)
- X-axis: date labels, `.month().day()` format
- Height: 140pt
- Card styling matches existing blocks

## Integration

In `AgentUsageView.body`, after `detailBlock`:

```swift
if selectedSource == .all, selectedTimeRange != .today {
    AgentUsageFlowChartView(dataPoints: tokenFlowData)
}
```

`tokenFlowData` is a computed property that builds `[TokenUsageDataPoint]` from `openCodeFilteredSnapshot` and `codexFilteredSnapshot`.

## Files Changed

| File | Change |
|------|--------|
| `Views/AgentUsageView.swift` | Add `TokenUsageDataPoint` struct, `tokenFlowData` property, conditional chart card in body |
| `Views/AgentUsageFlowChartView.swift` | New file — chart view with `Chart { LineMark + AreaMark }` |
| `pulse.xcodeproj/project.pbxproj` | Add new file to Sources build phase |

## What Isn't Changed

- `AgentUsageStore` — unchanged
- `AgentUsageModels` — unchanged
- `OpenCodeUsageModels/Store` — unchanged
- `CodexUsageModels/Query` — unchanged
- All other views — unchanged
