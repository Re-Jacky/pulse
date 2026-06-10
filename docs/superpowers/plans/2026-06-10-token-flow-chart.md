# Token Flow Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a line chart to the Agent Usage "All" view showing merged OpenCode + Codex token usage over time.

**Architecture:** A new `AgentUsageFlowChartView` renders a SwiftUI Chart with LineMark + AreaMark. A `tokenFlowData` computed property on `AgentUsageView` buckets merged sessions by date. The chart card is conditionally shown after `detailBlock` when source is All and range is not Today.

**Tech Stack:** SwiftUI Charts (macOS 14.0+), AppKit, Swift 5.9

---

### Task 1: Add data types and bucketing logic to AgentUsageView

**Files:**
- Modify: `Views/AgentUsageView.swift`

- [ ] **Step 1: Add TokenUsageDataPoint struct near bottom of file** (before closing `}`)

Add this struct outside the view body, at file scope (e.g., before the last newline):

```swift
struct TokenUsageDataPoint: Identifiable {
    let date: Date
    let totalTokens: Int
    var id: Date { date }
}
```

- [ ] **Step 2: Add tokenFlowData computed property** (inside `AgentUsageView`, after `summary` property around line 62)

```swift
private var tokenFlowData: [TokenUsageDataPoint] {
    guard selectedSource == .all, selectedTimeRange != .today else { return [] }

    let now = Date()
    let calendar = Calendar.current

    let minOC = openCodeFilteredSnapshot.sessions.min(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
    let minCX = codexFilteredSnapshot.sessions.min(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
    guard let earliest = [minOC, minCX].compactMap({ $0 }).min() else { return [] }

    let totalDays = calendar.dateComponents([.day], from: earliest, to: now).day.flatMap({ $0 > 0 ? $0 : 1 }) ?? 1
    let bucketSize: Int
    switch selectedTimeRange {
    case .allTime: bucketSize = max(1, Int(ceil(Double(totalDays) / 30)))
    default: bucketSize = 1
    }

    var entries: [(date: Date, tokens: Int)] = []
    for s in openCodeFilteredSnapshot.sessions {
        entries.append((s.updatedAt, s.totalTokens))
    }
    for s in codexFilteredSnapshot.sessions {
        entries.append((s.updatedAt, s.tokensUsed))
    }

    var buckets: [TokenUsageDataPoint] = []
    var cursor = earliest
    while cursor <= now {
        guard let bucketEnd = calendar.date(byAdding: .day, value: bucketSize, to: cursor) else { break }
        let sum = entries
            .filter { $0.date >= cursor && $0.date < bucketEnd }
            .reduce(0) { $0 + $1.tokens }
        buckets.append(TokenUsageDataPoint(date: cursor, totalTokens: sum))
        cursor = bucketEnd
    }
    return buckets
}
```

- [ ] **Step 3: Wire chart into body** — after `detailBlock` at around line 165, add:

```swift
if selectedSource == .all && selectedTimeRange != .today {
    AgentUsageFlowChartView(dataPoints: tokenFlowData)
}
```

- [ ] **Step 4: Verify no compilation errors**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -20`
Expected: Shows `** BUILD FAILED **` because `AgentUsageFlowChartView` doesn't exist yet — that's fine, the struct reference doesn't exist.

---

### Task 2: Create AgentUsageFlowChartView

**Files:**
- Create: `Views/AgentUsageFlowChartView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import Charts

struct AgentUsageFlowChartView: View {
    let dataPoints: [TokenUsageDataPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Token Flow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

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
                .interpolationMethod(.catmullRom)
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
                        .foregroundColor(.appSecondaryText)
                }
            }
            .frame(height: 140)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
```

---

### Task 3: Add file to Xcode project

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Find the last Views/*.swift reference in the pbxproj**

Run: `grep -n 'Views/' pulse.xcodeproj/project.pbxproj | grep '\.swift' | tail -5`

- [ ] **Step 2: Add AgentUsageFlowChartView.swift via add_files.rb**

Run: `ruby add_files.rb pulse/Views/AgentUsageFlowChartView.swift`

Expected: Script reports file added. If no script, manually add the reference to the pbxproj by copying an existing View file entry pattern and updating UUIDs.

---

### Task 4: Build and verify

**Files:**
- None

- [ ] **Step 1: Clean build**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify no warnings**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep warning | head -5`

Expected: No warnings related to our changes (or zero warnings total).

- [ ] **Step 3: Commit changes**

```bash
git add pulse/Views/AgentUsageFlowChartView.swift pulse/Views/AgentUsageView.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add token flow line chart to Agent Usage All view"
```
