# Agent Usage Date Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Agent usage fixed range selector with a compact native-feeling date picker that supports presets, single-day selection, and inclusive custom ranges while keeping data fetch and refresh behavior unchanged.

**Architecture:** Introduce a richer persisted date-selection model that resolves to local-calendar day intervals for all in-memory derivation paths. Keep refresh and load logic unchanged, refactor store derivation helpers to consume resolved day intervals, and add isolated SwiftUI picker views for the compact trigger and popover UI.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit-hosted macOS app, XCTest, Xcode project build/test via `xcodebuild`

## Global Constraints

- The app is a native macOS menu bar app; the picker should feel native and compact in the existing panel.
- The current refresh behavior stays unchanged.
- SQL access must remain in the existing refresh/load path only.
- Range switching must remain purely in-memory.
- Day bucketing must remain local-calendar based, not raw 86400-second window math.
- The feature must only change how the target day or date range is selected. It must not change how agent usage data is fetched, refreshed, or loaded from disk.
- Keep semantic colors from `pulse/Views/Colors.swift`; avoid hard-coded light/dark values.
- When adding Swift files, update the Xcode project too; use `add_files.rb` or edit `pulse.xcodeproj/project.pbxproj` directly.

---

### Task 1: Add a richer date selection model and resolution helpers

**Files:**
- Modify: `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageModels.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageViewData.swift`
- Test: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Consumes: existing `agentUsageDayIdentifier(for:calendar:) -> Int`
- Produces: `enum AgentDatePreset: String, CaseIterable, Hashable`, `enum AgentDateSelection: Equatable, Hashable`, `func agentUsageDayInterval(for: AgentDateSelection, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Range<Int>?`, `var label: String` helpers for preset-trigger display, and `AgentUsageSelection.dateSelection`

- [ ] **Step 1: Write the failing tests**

```swift
func testAgentUsageDayIntervalForPresetTodayUsesOneLocalDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = Date(timeIntervalSince1970: 1_720_558_400) // 2024-07-01 12:00:00 UTC

    let interval = agentUsageDayInterval(for: .preset(.today), now: now, calendar: calendar)

    XCTAssertEqual(interval?.count, 1)
}

func testAgentUsageDayIntervalForSingleDayMatchesSelectedDay() {
    let day = 19_900

    let interval = agentUsageDayInterval(for: .singleDay(day), now: Date(), calendar: .gregorianUTCForTests)

    XCTAssertEqual(interval, day..<(day + 1))
}

func testAgentUsageDayIntervalForRangeNormalizesReversedEndpoints() {
    let interval = agentUsageDayInterval(for: .dayRange(startDay: 20, endDay: 18), now: Date(), calendar: .gregorianUTCForTests)

    XCTAssertEqual(interval, 18..<21)
}

func testAgentUsageDayIntervalForAllTimeReturnsNil() {
    XCTAssertNil(agentUsageDayInterval(for: .preset(.allTime), now: Date(), calendar: .gregorianUTCForTests))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
Expected: FAIL with compile errors because `AgentDateSelection`, `AgentDatePreset`, `agentUsageDayInterval`, or `.gregorianUTCForTests` are not defined yet.

- [ ] **Step 3: Write the minimal implementation**

```swift
enum AgentDatePreset: String, CaseIterable, Hashable {
    case allTime = "all_time"
    case today = "today"
    case last7Days = "last_7_days"
    case last30Days = "last_30_days"

    var label: String {
        switch self {
        case .allTime: return "All Time"
        case .today: return "Today"
        case .last7Days: return "7 Days"
        case .last30Days: return "30 Days"
        }
    }
}

enum AgentDateSelection: Equatable, Hashable {
    case preset(AgentDatePreset)
    case singleDay(Int)
    case dayRange(startDay: Int, endDay: Int)
}

func agentUsageDayInterval(
    for selection: AgentDateSelection,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
) -> Range<Int>? {
    switch selection {
    case .preset(.allTime):
        return nil
    case .preset(.today):
        let day = agentUsageDayIdentifier(for: now, calendar: calendar)
        return day..<(day + 1)
    case .preset(.last7Days):
        let currentDay = agentUsageDayIdentifier(for: now, calendar: calendar)
        return (currentDay - 6)..<(currentDay + 1)
    case .preset(.last30Days):
        let currentDay = agentUsageDayIdentifier(for: now, calendar: calendar)
        return (currentDay - 29)..<(currentDay + 1)
    case let .singleDay(day):
        return day..<(day + 1)
    case let .dayRange(startDay, endDay):
        let lower = min(startDay, endDay)
        let upper = max(startDay, endDay)
        return lower..<(upper + 1)
    }
}

struct AgentUsageSelection: Equatable, Hashable {
    let source: AgentSource
    let dateSelection: AgentDateSelection
    let projectDirectory: String?
    let sessionID: String?
    let modelGroupBy: AgentModelGroupBy
}
```

- [ ] **Step 4: Add test-only calendar helper if missing**

```swift
private extension Calendar {
    static var gregorianUTCForTests: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
Expected: PASS for the new interval-resolution tests.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift pulse/Managers/AgentUsageViewData.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: add agent usage date selection model"
```

### Task 2: Refactor store derivation to use resolved day intervals without changing refresh behavior

**Files:**
- Modify: `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageStore.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageModels.swift`
- Test: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageStoreTests.swift`
- Test: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageViewDataTests.swift`

**Interfaces:**
- Consumes: `AgentUsageSelection.dateSelection`, `agentUsageDayInterval(for:now:calendar:) -> Range<Int>?`
- Produces: `private func dayInterval(for selection: AgentDateSelection) -> Range<Int>?`, updated `derivedData(for:)`, updated aggregated snapshot helpers and in-memory bucket filters that accept `AgentDateSelection` or `Range<Int>?`

- [ ] **Step 1: Write the failing tests**

```swift
func testDerivedDataForSingleDayUsesOnlyBucketsInThatDay() {
    let store = makeStoreWithLoadedState(
        openCodeBuckets: [
            openCodeBucket(day: 100, totalTokens: 50, sessionID: "oc-1"),
            openCodeBucket(day: 101, totalTokens: 75, sessionID: "oc-1")
        ],
        codexBuckets: []
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .openCode,
        dateSelection: .singleDay(101),
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertEqual(data.summary.totalTokens, 75)
}

func testDerivedDataForRangeUsesInclusiveEndpoints() {
    let store = makeStoreWithLoadedState(
        openCodeBuckets: [
            openCodeBucket(day: 100, totalTokens: 10, sessionID: "oc-1"),
            openCodeBucket(day: 101, totalTokens: 20, sessionID: "oc-1"),
            openCodeBucket(day: 102, totalTokens: 30, sessionID: "oc-1")
        ],
        codexBuckets: []
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .openCode,
        dateSelection: .dayRange(startDay: 100, endDay: 102),
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertEqual(data.summary.totalTokens, 60)
}

func testDateSelectionDoesNotChangeRefreshGeneration() {
    let store = makeStoreWithLoadedState(openCodeBuckets: [openCodeBucket(day: 100, totalTokens: 10, sessionID: "oc-1")], codexBuckets: [])
    let initialGeneration = store.debugRefreshGenerationForTests

    _ = store.derivedData(for: AgentUsageSelection(source: .openCode, dateSelection: .singleDay(100), projectDirectory: nil, sessionID: nil, modelGroupBy: .model))
    _ = store.derivedData(for: AgentUsageSelection(source: .openCode, dateSelection: .dayRange(startDay: 100, endDay: 100), projectDirectory: nil, sessionID: nil, modelGroupBy: .model))

    XCTAssertEqual(store.debugRefreshGenerationForTests, initialGeneration)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/AgentUsageViewDataTests`
Expected: FAIL because `AgentUsageStore` still branches on `selection.timeRange` and helper factories do not yet accept the new selection model.

- [ ] **Step 3: Write the minimal implementation**

```swift
func derivedData(for inputSelection: AgentUsageSelection) -> AgentUsageDerivedViewData {
    let selection = reconcile(inputSelection)
    let cacheKey = DerivedDataCacheKey(selection: selection, refreshGeneration: state.refreshGeneration)
    if let derivedDataCache, derivedDataCache.key == cacheKey {
        return derivedDataCache.value
    }

    let interval = dayInterval(for: selection.dateSelection)

    let openCodeSnapshot = aggregatedSnapshot(for: selection.dateSelection, interval: interval)
    let codexSnapshot = aggregatedCodexSnapshot(for: selection.dateSelection, interval: interval)
    let scope = selection.scope

    let ocLatestBySession = openCodeLatestActivityBySession(interval: interval, snapshot: openCodeSnapshot)
    let cxLatestBySession = codexLatestActivityBySession(interval: interval, snapshot: codexSnapshot)

    // Preserve the remainder of the derivation flow, replacing timeRange-based
    // filtering with interval-based filtering only.
}

private func dayInterval(for selection: AgentDateSelection) -> Range<Int>? {
    agentUsageDayInterval(for: selection)
}

private func aggregatedSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> OpenCodeUsageSnapshot {
    guard let interval else { return state.openCodeCumulativeSnapshot }
    // Existing bucket aggregation loop, replacing dayRange checks with interval.
}

private func aggregatedCodexSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> CodexUsageSnapshot {
    guard let interval else { return state.codexSnapshot }
    // Existing bucket aggregation loop, replacing dayRange checks with interval.
}
```

- [ ] **Step 4: Add targeted test helpers needed by the new assertions**

```swift
extension AgentUsageStore {
    var debugRefreshGenerationForTests: Int { state.refreshGeneration }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/AgentUsageViewDataTests`
Expected: PASS for the new single-day, inclusive-range, and no-refresh-regression tests.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/Managers/AgentUsageModels.swift pulseTests/AgentUsageStoreTests.swift pulseTests/AgentUsageViewDataTests.swift
git commit -m "refactor: use interval-based agent usage date filtering"
```

### Task 3: Add persisted date-selection UI state and migration from existing presets

**Files:**
- Modify: `/Users/zyao/Desktop/pulse/pulse/Views/AgentUsageView.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageModels.swift`
- Test: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageViewDataTests.swift`

**Interfaces:**
- Consumes: `AgentDatePreset`, `AgentDateSelection`, existing `@AppStorage` usage in `AgentUsageView`
- Produces: persisted keys for selection kind and endpoints, helpers such as `AgentDateSelectionStorage.load(...) -> AgentDateSelection` and `AgentDateSelectionStorage.save(...)`

- [ ] **Step 1: Write the failing tests**

```swift
func testLegacyPresetRawValueMigratesToPresetSelection() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.set("last_7_days", forKey: "agentUsageSelectedTimeRange")

    let selection = AgentDateSelectionStorage.load(userDefaults: defaults, calendar: .gregorianUTCForTests, now: Date(timeIntervalSince1970: 1_720_558_400))

    XCTAssertEqual(selection, .preset(.last7Days))
}

func testExplicitRangeRoundTripsThroughStorage() {
    let defaults = UserDefaults(suiteName: #function)!
    let selection = AgentDateSelection.dayRange(startDay: 100, endDay: 104)

    AgentDateSelectionStorage.save(selection, userDefaults: defaults)

    XCTAssertEqual(AgentDateSelectionStorage.load(userDefaults: defaults, calendar: .gregorianUTCForTests, now: Date()), selection)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageViewDataTests`
Expected: FAIL because `AgentDateSelectionStorage` and migration logic do not exist.

- [ ] **Step 3: Write the minimal implementation**

```swift
enum AgentDateSelectionStorage {
    static let legacyPresetKey = "agentUsageSelectedTimeRange"
    static let kindKey = "agentUsageDateSelectionKind"
    static let presetKey = "agentUsageDatePreset"
    static let startDayKey = "agentUsageDateStartDay"
    static let endDayKey = "agentUsageDateEndDay"

    static func load(userDefaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) -> AgentDateSelection {
        if let kind = userDefaults.string(forKey: kindKey) {
            switch kind {
            case "preset":
                let raw = userDefaults.string(forKey: presetKey) ?? AgentDatePreset.today.rawValue
                return .preset(AgentDatePreset(rawValue: raw) ?? .today)
            case "single":
                return .singleDay(userDefaults.integer(forKey: startDayKey))
            case "range":
                return .dayRange(startDay: userDefaults.integer(forKey: startDayKey), endDay: userDefaults.integer(forKey: endDayKey))
            default:
                break
            }
        }

        if let legacy = userDefaults.string(forKey: legacyPresetKey), let preset = AgentDatePreset(rawValue: legacy) {
            return .preset(preset)
        }

        return .preset(.today)
    }

    static func save(_ selection: AgentDateSelection, userDefaults: UserDefaults = .standard) {
        switch selection {
        case let .preset(preset):
            userDefaults.set("preset", forKey: kindKey)
            userDefaults.set(preset.rawValue, forKey: presetKey)
        case let .singleDay(day):
            userDefaults.set("single", forKey: kindKey)
            userDefaults.set(day, forKey: startDayKey)
            userDefaults.removeObject(forKey: endDayKey)
        case let .dayRange(startDay, endDay):
            userDefaults.set("range", forKey: kindKey)
            userDefaults.set(startDay, forKey: startDayKey)
            userDefaults.set(endDay, forKey: endDayKey)
        }
    }
}
```

- [ ] **Step 4: Wire `AgentUsageView` to load and save `AgentDateSelection`**

```swift
@State private var persistedDateSelection = AgentDateSelectionStorage.load()

private var selection: AgentUsageSelection {
    AgentUsageSelection(
        source: selectedSource,
        dateSelection: persistedDateSelection,
        projectDirectory: selectedProjectDirectory.nilIfEmpty,
        sessionID: selectedSessionID.nilIfEmpty,
        modelGroupBy: selectedModelGroupBy
    )
}

private func persistDateSelection(_ selection: AgentDateSelection) {
    persistedDateSelection = selection
    AgentDateSelectionStorage.save(selection)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageViewDataTests`
Expected: PASS for legacy migration and explicit range persistence tests.

- [ ] **Step 6: Commit**

```bash
git add pulse/Views/AgentUsageView.swift pulse/Managers/AgentUsageModels.swift pulseTests/AgentUsageViewDataTests.swift
git commit -m "feat: persist agent usage date selection"
```

### Task 4: Build the compact date trigger and popover picker UI

**Files:**
- Create: `/Users/zyao/Desktop/pulse/pulse/Views/AgentDateSelectionPicker.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulse/Views/AgentUsageView.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulse.xcodeproj/project.pbxproj`
- Test: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageViewDataTests.swift`

**Interfaces:**
- Consumes: `AgentDateSelection`, `AgentDatePreset`, `agentUsageDayIdentifier(for:calendar:)`
- Produces: `struct AgentDateSelectionPicker: View`, `struct AgentDateSelectionTriggerLabel`, `init(selection: AgentDateSelection, onApply: @escaping (AgentDateSelection) -> Void)`

- [ ] **Step 1: Write the failing tests**

```swift
func testDateSelectionSummaryLabelForPresetToday() {
    XCTAssertEqual(AgentDateSelectionTriggerLabel.text(for: .preset(.today), calendar: .gregorianUTCForTests), "Today")
}

func testDateSelectionSummaryLabelForSingleDayUsesFormattedDate() {
    XCTAssertEqual(
        AgentDateSelectionTriggerLabel.text(for: .singleDay(19_905), calendar: .gregorianUTCForTests),
        "Jul 5, 2024"
    )
}

func testDateSelectionSummaryLabelForRangeUsesBothDates() {
    XCTAssertEqual(
        AgentDateSelectionTriggerLabel.text(for: .dayRange(startDay: 19_905, endDay: 19_907), calendar: .gregorianUTCForTests),
        "Jul 5 - Jul 7"
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageViewDataTests`
Expected: FAIL because `AgentDateSelectionPicker` and `AgentDateSelectionTriggerLabel` do not exist.

- [ ] **Step 3: Write the minimal implementation**

```swift
struct AgentDateSelectionPicker: View {
    let selection: AgentDateSelection
    let onApply: (AgentDateSelection) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(AgentDateSelectionTriggerLabel.text(for: selection))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.appPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appFieldBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.appFieldBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentDateSelectionPopover(
                initialSelection: selection,
                onApply: { updated in
                    onApply(updated)
                    isPresented = false
                }
            )
        }
    }
}
```

- [ ] **Step 4: Integrate the picker into the Agent header and add the new file to Xcode**

```swift
HStack(spacing: 8) {
    // existing source picker

    AgentDateSelectionPicker(selection: selection.dateSelection) { updatedSelection in
        persistDateSelection(updatedSelection)
    }
}
```

Run: `ruby add_files.rb pulse/Views/AgentDateSelectionPicker.swift`
Expected: The new Swift file is added to the `pulse` target in `pulse.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run targeted tests to verify labels and compilation**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageViewDataTests`
Expected: PASS for trigger-label formatting tests and no compile errors from the new picker UI.

- [ ] **Step 6: Commit**

```bash
git add pulse/Views/AgentDateSelectionPicker.swift pulse/Views/AgentUsageView.swift pulse.xcodeproj/project.pbxproj pulseTests/AgentUsageViewDataTests.swift
git commit -m "feat: add agent usage date picker UI"
```

### Task 5: Verify end-to-end behavior and guard against refresh regressions

**Files:**
- Modify: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageStoreTests.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageViewDataTests.swift`
- Modify: `/Users/zyao/Desktop/pulse/pulse/Views/AgentUsageView.swift` (only if small follow-up fixes are required)

**Interfaces:**
- Consumes: all prior tasks
- Produces: end-to-end regression coverage for preset migration, trigger label behavior, interval-based derivation, and refresh invariants

- [ ] **Step 1: Add final regression tests**

```swift
func testPresetShortcutAndEquivalentExplicitRangeProduceSameSummaryForToday() {
    let today = 200
    let store = makeStoreWithLoadedState(
        openCodeBuckets: [openCodeBucket(day: today, totalTokens: 42, sessionID: "oc-1")],
        codexBuckets: []
    )

    let preset = store.derivedData(for: AgentUsageSelection(source: .openCode, dateSelection: .preset(.today), projectDirectory: nil, sessionID: nil, modelGroupBy: .model))
    let explicit = store.derivedData(for: AgentUsageSelection(source: .openCode, dateSelection: .singleDay(today), projectDirectory: nil, sessionID: nil, modelGroupBy: .model))

    XCTAssertEqual(preset.summary.totalTokens, explicit.summary.totalTokens)
}
```

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
Expected: PASS for `pulseTests` with no failures.

- [ ] **Step 3: Run app build**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Fix any final small issues and re-run verification**

```swift
// Only if needed: keep follow-up fixes tightly scoped to picker formatting,
// persistence wiring, or interval resolution uncovered by Task 5 verification.
```

- [ ] **Step 5: Commit**

```bash
git add pulseTests/AgentUsageStoreTests.swift pulseTests/AgentUsageViewDataTests.swift pulse/Views/AgentUsageView.swift
git commit -m "test: verify agent usage date picker integration"
```
