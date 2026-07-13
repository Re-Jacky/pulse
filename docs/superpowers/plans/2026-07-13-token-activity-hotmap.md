# Token Activity Hotmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a persisted Activity/Trend switcher to the Agent tab token chart, defaulting to a GitHub-style token activity hotmap.

**Architecture:** Keep `AgentUsageStore` and `TokenUsageDataPoint` unchanged. Refactor `AgentUsageFlowChartView` into a small container with an `@AppStorage` mode picker, a new activity hotmap renderer, and the existing chart logic moved into a trend renderer.

**Tech Stack:** Swift 5.9+, SwiftUI, Charts, AppKit menu bar app, no external dependencies.

## Global Constraints

- Keep semantic colors from `pulse/Views/Colors.swift`; avoid hard-coded light/dark values.
- Do not introduce new database queries or refresh behavior.
- Keep `TokenUsageDataPoint` unchanged.
- Preserve the existing `AgentUsageView` call site contract: pass `[TokenUsageDataPoint]` only.
- Empty or hidden chart behavior stays unchanged.
- `Activity` is the default selected mode and persists with `@AppStorage`.

---

### Task 1: Refactor Token Chart Into Activity/Trend Modes

**Files:**
- Modify: `pulse/Views/AgentUsageFlowChartView.swift`
- Verify: `pulse/Views/AgentUsageView.swift`

**Interfaces:**
- Consumes: `TokenUsageDataPoint` with `date: Date`, `totalTokens: Int`, `bucketSizeDays: Int`
- Produces: `AgentUsageFlowChartView(dataPoints: [TokenUsageDataPoint])` with unchanged initializer

- [x] **Step 1: Inspect the current chart call site**

Run:

```bash
codegraph explore "AgentUsageFlowChartView AgentUsageView tokenFlowData TokenUsageDataPoint"
```

Expected: `AgentUsageView` only passes `data.tokenFlowData` to `AgentUsageFlowChartView`, so no call site changes are required.

- [x] **Step 2: Replace `AgentUsageFlowChartView.swift` with mode-aware implementation**

Use this structure:

```swift
import SwiftUI
import Charts

private enum AgentUsageChartMode: String, CaseIterable, Identifiable {
    case activity
    case trend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .trend: return "Trend"
        }
    }
}

struct AgentUsageFlowChartView: View {
    let dataPoints: [TokenUsageDataPoint]
    @AppStorage("agentUsageTokenChartMode") private var selectedModeRawValue = AgentUsageChartMode.activity.rawValue

    private var selectedMode: AgentUsageChartMode {
        AgentUsageChartMode(rawValue: selectedModeRawValue) ?? .activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Token Activity")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Spacer()

                Picker("", selection: $selectedModeRawValue) {
                    ForEach(AgentUsageChartMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if let bucketSizeDays = bucketSizeDays, bucketSizeDays > 1 {
                Text("Each point combines \(bucketSizeDays) days.")
                    .font(.system(size: 10))
                    .foregroundColor(.appSecondaryText)
            }

            switch selectedMode {
            case .activity:
                AgentUsageActivityHotmapView(dataPoints: dataPoints)
            case .trend:
                AgentUsageTrendChartView(dataPoints: dataPoints)
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bucketSizeDays: Int? {
        let sizes = Set(dataPoints.map(\.bucketSizeDays))
        return sizes.count == 1 ? sizes.first : nil
    }
}
```

- [x] **Step 3: Add `AgentUsageActivityHotmapView` below the container**

Use daily calendar columns when `bucketSizeDays == 1`, and compact sequential cells otherwise:

```swift
private struct AgentUsageActivityHotmapView: View {
    let dataPoints: [TokenUsageDataPoint]

    private let calendar = Calendar.autoupdatingCurrent
    private let cellSize: CGFloat = 10
    private let cellSpacing: CGFloat = 4

    var body: some View {
        if bucketSizeDays == 1 {
            LazyHGrid(rows: rows, alignment: .top, spacing: cellSpacing) {
                ForEach(calendarCells) { cell in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: cell.totalTokens))
                        .frame(width: cellSize, height: cellSize)
                        .help(helpText(for: cell))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: (cellSize * 7) + (cellSpacing * 6))
        } else {
            LazyVGrid(columns: sequentialColumns, alignment: .leading, spacing: cellSpacing) {
                ForEach(dataPoints) { point in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: point.totalTokens))
                        .frame(width: cellSize, height: cellSize)
                        .help("\(compact(point.totalTokens)) tokens starting \(shortDate(point.date))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rows: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
    }

    private var sequentialColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 24)
    }

    private var bucketSizeDays: Int {
        dataPoints.first?.bucketSizeDays ?? 1
    }

    private var maxTokens: Int {
        max(dataPoints.map(\.totalTokens).max() ?? 0, 1)
    }

    private var tokenByDay: [Int: Int] {
        Dictionary(uniqueKeysWithValues: dataPoints.map { point in
            (agentUsageDayIdentifier(for: point.date, calendar: calendar), point.totalTokens)
        })
    }

    private var calendarCells: [ActivityCell] {
        guard let firstDate = dataPoints.first?.date,
              let lastDate = dataPoints.last?.date else { return [] }
        let firstDay = agentUsageDayIdentifier(for: firstDate, calendar: calendar)
        let lastDay = agentUsageDayIdentifier(for: lastDate, calendar: calendar)
        let firstWeekdayIndex = weekdayIndex(for: firstDate)
        let startDay = firstDay - firstWeekdayIndex
        let dayCount = lastDay - startDay + 1
        let paddedCount = Int(ceil(Double(max(dayCount, 1)) / 7.0)) * 7

        return (0..<paddedCount).map { offset in
            let day = startDay + offset
            let date = date(forDayIdentifier: day)
            let isInRange = day >= firstDay && day <= lastDay
            return ActivityCell(day: day, date: date, totalTokens: isInRange ? tokenByDay[day, default: 0] : 0, isInRange: isInRange)
        }
    }

    private func color(for tokens: Int) -> Color {
        guard tokens > 0 else { return Color.appFieldBorder.opacity(0.35) }
        let ratio = Double(tokens) / Double(maxTokens)
        switch ratio {
        case ..<0.25: return Color.accentColor.opacity(0.28)
        case ..<0.5: return Color.accentColor.opacity(0.45)
        case ..<0.75: return Color.accentColor.opacity(0.65)
        default: return Color.accentColor.opacity(0.9)
        }
    }

    private func weekdayIndex(for date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private func date(forDayIdentifier day: Int) -> Date {
        Date(timeIntervalSince1970: Double(day * 86_400_000) / 1000)
    }

    private func helpText(for cell: ActivityCell) -> String {
        if cell.isInRange == false {
            return "Outside selected range"
        }
        return "\(compact(cell.totalTokens)) tokens on \(shortDate(cell.date))"
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private struct ActivityCell: Identifiable {
        let day: Int
        let date: Date
        let totalTokens: Int
        let isInRange: Bool

        var id: Int { day }
    }
}
```

- [x] **Step 4: Move the existing Chart code into `AgentUsageTrendChartView`**

Keep the existing visual behavior, title removed because the container title is now shared:

```swift
private struct AgentUsageTrendChartView: View {
    let dataPoints: [TokenUsageDataPoint]

    var body: some View {
        Chart(dataPoints) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value("Tokens", point.totalTokens)
            )
            .foregroundStyle(
                LinearGradient(colors: [
                    Color.accentColor.opacity(0.3),
                    Color.accentColor.opacity(0.02)
                ], startPoint: .top, endPoint: .bottom)
            )

            LineMark(
                x: .value("Date", point.date),
                y: .value("Tokens", point.totalTokens)
            )
            .foregroundStyle(Color.accentColor)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.monotone)
        }
        .chartYAxis {
            AxisMarks(preset: .extended, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(Color.appDivider)
                AxisValueLabel {
                    if let val = v.as(Int.self) {
                        Text(compact(val))
                            .font(.system(size: 9))
                            .foregroundColor(.appSecondaryText)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month().day(), centered: true)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
        .frame(height: 140)
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
```

- [x] **Step 5: Run the build**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: Build succeeds without Swift compiler errors.

- [x] **Step 6: Run the test suite**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
```

Expected: Test suite passes.

- [x] **Step 7: Commit implementation**

Run:

```bash
git add pulse/Views/AgentUsageFlowChartView.swift docs/superpowers/plans/2026-07-13-token-activity-hotmap.md
git commit -m "feat: add token activity hotmap"
```

Expected: Commit succeeds with only the chart implementation and plan document staged.

### Task 2: Make Token Activity All-Time Calendar Only

**Files:**
- Modify: `pulse/Managers/AgentUsageViewData.swift`
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulse/Views/AgentUsageView.swift`
- Modify: `pulse/Views/AgentUsageFlowChartView.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Consumes: `AgentUsageSelection.dateSelection`
- Produces: `AgentUsageDerivedViewData.activityCalendarData: [TokenUsageDataPoint]`
- Produces: `AgentUsageFlowChartView(trendDataPoints: [TokenUsageDataPoint], activityDataPoints: [TokenUsageDataPoint])`

- [x] **Step 1: Add failing tests**

Add store tests proving non-all-time selections hide token activity and all-time activity data remains daily while trend data may be compressed.

- [x] **Step 2: Verify tests fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests
```

Expected: New tests fail because `showsTokenFlow` is still true for non-all-time ranges and `activityCalendarData` does not exist yet.

- [x] **Step 3: Add daily all-time activity data**

Add `activityCalendarData` to `AgentUsageDerivedViewData`, build it from uncompressed all-time daily totals, and make `showsTokenFlow` true only for non-session all-time selections with activity.

- [x] **Step 4: Render only all-time Token Activity**

Update `AgentUsageView` to pass trend and activity data into `AgentUsageFlowChartView`, and update the hotmap renderer to use natural current/latest-year calendar cells with month labels.

- [x] **Step 5: Verify focused tests pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests
```

Expected: Focused tests pass.

- [x] **Step 6: Verify full build and tests pass**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
```

Expected: Build and full test suite pass.

- [x] **Step 7: Commit follow-up**

Run:

```bash
git add docs/superpowers/specs/2026-07-13-token-activity-hotmap-design.md docs/superpowers/plans/2026-07-13-token-activity-hotmap.md pulse/Managers/AgentUsageViewData.swift pulse/Managers/AgentUsageStore.swift pulse/Views/AgentUsageView.swift pulse/Views/AgentUsageFlowChartView.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: show token activity as all-time calendar"
```
