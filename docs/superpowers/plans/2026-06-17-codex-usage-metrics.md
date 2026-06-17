# Codex Usage Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Codex usage reporting so ranged Codex views expose native `total_tokens` plus input, output, reasoning, and cache-read metrics from transcripts while keeping views fully data-driven.

**Architecture:** Keep SQLite `threads` as the metadata source and transcript-derived `CodexDailyBucket` values as the ranged usage source. Follow the existing Pulse flow of query manager -> repository -> `AgentUsageStore` -> derived view data -> SwiftUI views, with no SQL or transcript parsing in child components.

**Tech Stack:** Swift 5.9, Foundation, SQLite3, AppKit/SwiftUI, XCTest, `xcodebuild`

---

## File Structure

- Modify: `pulse/Managers/CodexUsageModels.swift`
  - Expand Codex bucket/session summary structures to carry detailed token fields.
- Modify: `pulse/Managers/CodexUsageQuery.swift`
  - Parse transcript token events into detailed daily buckets while preserving native `total_tokens`.
- Modify: `pulse/Managers/AgentUsageRepository.swift`
  - Keep repository surface aligned with detailed Codex bucket loading.
- Modify: `pulse/Managers/AgentUsageViewData.swift`
  - Continue storing precomputed Codex bucket data in loaded state.
- Modify: `pulse/Managers/AgentUsageStore.swift`
  - Rebuild ranged Codex snapshots from detailed buckets and feed normalized summary fields to the UI.
- Modify: `pulseTests/AgentUsageStoreTests.swift`
  - Add regression coverage for detailed Codex bucket parsing and ranged store aggregation.
- Modify: `pulseTests/AgentUsageViewDataTests.swift`
  - Assert Codex derived view data exposes the richer summary fields through the existing UI contract.
- Modify: `pulse.xcodeproj/project.pbxproj`
  - Bump `MARKETING_VERSION` for the bug-fix release if it has not already been bumped in the branch under implementation.

### Task 1: Expand Codex Data Models

**Files:**
- Modify: `pulse/Managers/CodexUsageModels.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

- [ ] **Step 1: Write the failing model-level expectations in the store test file**

```swift
func testCodexLoadDailyBucketsSplitsDetailedCrossDayUsageFromTranscript() throws {
    XCTAssertEqual(
        buckets,
        [
            CodexDailyBucket(
                sessionID: "thread_1",
                day: 20620,
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 40,
                totalTokens: 120
            ),
            CodexDailyBucket(
                sessionID: "thread_1",
                day: 20621,
                inputTokens: 90,
                outputTokens: 10,
                reasoningTokens: 3,
                cacheReadTokens: 40,
                totalTokens: 100
            )
        ]
    )
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadDailyBucketsSplitsDetailedCrossDayUsageFromTranscript`

Expected: FAIL because `CodexDailyBucket` does not yet expose `inputTokens`, `outputTokens`, `reasoningTokens`, `cacheReadTokens`, and `totalTokens`.

- [ ] **Step 3: Update the Codex models with detailed token fields**

```swift
struct CodexSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let modelProvider: String
    let tokensUsed: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let cacheReadTokens: Int?
    let reasoningEffort: String
    let threadSource: String
    let agentNickname: String?
    let agentRole: String?
    let createdAt: Date
    let updatedAt: Date
}

struct CodexDailyBucket: Equatable {
    let sessionID: String
    let day: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
}
```

- [ ] **Step 4: Update Codex summary aggregation to populate normalized detailed metrics**

```swift
static func makeSummary(from sessions: [CodexSessionRecord]) -> AgentUsageSummary {
    AgentUsageSummary(
        totalTokens: sessions.reduce(0) { $0 + $1.tokensUsed },
        inputTokens: reduceOptional(\.inputTokens, sessions: sessions),
        outputTokens: reduceOptional(\.outputTokens, sessions: sessions),
        reasoningTokens: reduceOptional(\.reasoningTokens, sessions: sessions),
        cacheReadTokens: reduceOptional(\.cacheReadTokens, sessions: sessions),
        cacheWriteTokens: nil,
        sessionsCount: sessions.count,
        cost: nil,
        lastUpdated: sessions.map(\.updatedAt).max()
    )
}
```

- [ ] **Step 5: Run the focused test to verify the model compile surface is green**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadDailyBucketsSplitsDetailedCrossDayUsageFromTranscript`

Expected: still FAIL, but now because query/store logic has not been updated yet rather than missing fields.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/CodexUsageModels.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: expand codex usage models"
```

### Task 2: Parse Detailed Transcript Buckets

**Files:**
- Modify: `pulse/Managers/CodexUsageQuery.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

- [ ] **Step 1: Write failing transcript parsing assertions for native totals and detailed counters**

```swift
func testCodexLoadDailyBucketsPreservesNativeTotalTokens() throws {
    XCTAssertEqual(buckets[0].totalTokens, 120)
    XCTAssertEqual(buckets[0].inputTokens, 100)
    XCTAssertEqual(buckets[0].outputTokens, 20)
    XCTAssertEqual(buckets[0].reasoningTokens, 5)
    XCTAssertEqual(buckets[0].cacheReadTokens, 40)
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadDailyBucketsSplitsDetailedCrossDayUsageFromTranscript -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadDailyBucketsPreservesNativeTotalTokens`

Expected: FAIL because `loadDailyBuckets()` still only emits a single total.

- [ ] **Step 3: Replace the total-only cumulative usage helper with a detailed token usage helper**

```swift
fileprivate struct CumulativeUsage {
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
}
```

- [ ] **Step 4: Parse transcript `token_count` payloads into detailed cumulative values**

```swift
private func parseCumulativeUsage(payload: [String: Any]) -> CodexUsageQuery.CumulativeUsage? {
    guard let info = payload["info"] as? [String: Any] else { return nil }
    guard let usageObject = (info["total_token_usage"] as? [String: Any])
        ?? (info["last_token_usage"] as? [String: Any]) else {
        return nil
    }

    let inputTokens = usageObject["input_tokens"] as? Int ?? 0
    let outputTokens = usageObject["output_tokens"] as? Int ?? 0
    let reasoningTokens = usageObject["reasoning_output_tokens"] as? Int ?? 0
    let cacheReadTokens = usageObject["cached_input_tokens"] as? Int ?? 0
    let totalTokens = (usageObject["total_tokens"] as? Int)
        ?? (inputTokens + outputTokens + reasoningTokens + cacheReadTokens)

    return CodexUsageQuery.CumulativeUsage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        cacheReadTokens: cacheReadTokens,
        totalTokens: totalTokens
    )
}
```

- [ ] **Step 5: Emit detailed per-day deltas while preserving native `total_tokens`**

```swift
let delta = CodexDailyBucket(
    sessionID: currentSessionID,
    day: day,
    inputTokens: max(0, current.inputTokens - previous.inputTokens),
    outputTokens: max(0, current.outputTokens - previous.outputTokens),
    reasoningTokens: max(0, current.reasoningTokens - previous.reasoningTokens),
    cacheReadTokens: max(0, current.cacheReadTokens - previous.cacheReadTokens),
    totalTokens: max(0, current.totalTokens - previous.totalTokens)
)
```

- [ ] **Step 6: Aggregate detailed buckets by `(sessionID, day)`**

```swift
bucketTotals[key, default: CodexDailyBucket.zero(sessionID: sessionID, day: day)] =
    bucketTotals[key, default: .zero(sessionID: sessionID, day: day)].merging(delta)
```

- [ ] **Step 7: Run the focused tests to verify transcript parsing passes**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadDailyBucketsSplitsDetailedCrossDayUsageFromTranscript -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadDailyBucketsPreservesNativeTotalTokens -only-testing:pulseTests/AgentUsageStoreTests/testCodexLoadSnapshotReadsRowsStillInWAL`

Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add pulse/Managers/CodexUsageQuery.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: parse detailed codex transcript buckets"
```

### Task 3: Keep Repository and Loaded State in Sync

**Files:**
- Modify: `pulse/Managers/AgentUsageRepository.swift`
- Modify: `pulse/Managers/AgentUsageViewData.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

- [ ] **Step 1: Write a failing refresh test that expects detailed Codex buckets to be retained in store state**

```swift
func testRefreshAllLoadsDetailedCodexBuckets() {
    XCTAssertEqual(store.state.codexDailyBuckets[0].inputTokens, 50)
    XCTAssertEqual(store.state.codexDailyBuckets[0].totalTokens, 70)
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testRefreshAllLoadsDetailedCodexBuckets`

Expected: FAIL because the stub/state path does not yet carry detailed bucket values end-to-end.

- [ ] **Step 3: Keep the repository interface unchanged structurally but aligned with the richer bucket type**

```swift
protocol AgentUsageRepositorying {
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket]
}

func loadCodexDailyBuckets() throws -> [CodexDailyBucket] {
    try CodexUsageQuery.loadDailyBuckets()
}
```

- [ ] **Step 4: Ensure loaded state continues to store precomputed Codex buckets**

```swift
struct AgentUsageLoadedState: Equatable {
    let codexSnapshot: CodexUsageSnapshot
    let codexDailyBuckets: [CodexDailyBucket]
}
```

- [ ] **Step 5: Update the repository stubs in tests to use the richer bucket shape**

```swift
repository.codexDailyBuckets = [
    CodexDailyBucket(
        sessionID: "cx_1",
        day: todayDay,
        inputTokens: 50,
        outputTokens: 10,
        reasoningTokens: 5,
        cacheReadTokens: 5,
        totalTokens: 70
    )
]
```

- [ ] **Step 6: Run the focused test to verify the state path passes**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testRefreshAllLoadsDetailedCodexBuckets`

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/AgentUsageRepository.swift pulse/Managers/AgentUsageViewData.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "refactor: wire detailed codex buckets through repository state"
```

### Task 4: Rebuild Ranged Codex Snapshots from Detailed Buckets

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

- [ ] **Step 1: Write failing ranged summary tests for Codex detailed metrics**

```swift
func testDerivedDataUsesCodexDetailedBucketsForToday() {
    XCTAssertEqual(todayData.summary.totalTokens, 70)
    XCTAssertEqual(todayData.summary.inputTokens, 50)
    XCTAssertEqual(todayData.summary.outputTokens, 10)
    XCTAssertEqual(todayData.summary.reasoningTokens, 5)
    XCTAssertEqual(todayData.summary.cacheReadTokens, 5)
    XCTAssertNil(todayData.summary.cacheWriteTokens)
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testDerivedDataUsesCodexDetailedBucketsForToday`

Expected: FAIL because ranged Codex snapshots still only rebuild `tokensUsed`.

- [ ] **Step 3: Rebuild ranged Codex sessions with detailed optional fields**

```swift
return CodexSessionRecord(
    id: session.id,
    title: session.title,
    cwd: session.cwd,
    model: session.model,
    modelProvider: session.modelProvider,
    tokensUsed: inRange.reduce(0) { $0 + $1.totalTokens },
    inputTokens: inRange.reduce(0) { $0 + $1.inputTokens },
    outputTokens: inRange.reduce(0) { $0 + $1.outputTokens },
    reasoningTokens: inRange.reduce(0) { $0 + $1.reasoningTokens },
    cacheReadTokens: inRange.reduce(0) { $0 + $1.cacheReadTokens },
    reasoningEffort: session.reasoningEffort,
    threadSource: session.threadSource,
    agentNickname: session.agentNickname,
    agentRole: session.agentRole,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt
)
```

- [ ] **Step 4: Keep ranged Codex fallback behavior explicit**

```swift
if selection.timeRange == .allTime {
    codexSnapshot = state.codexSnapshot.filtered(to: selection.timeRange)
} else if state.codexDailyBuckets.isEmpty {
    codexSnapshot = CodexUsageSnapshot(sessions: [])
} else {
    codexSnapshot = aggregatedCodexSnapshot(for: selection.timeRange)
}
```

- [ ] **Step 5: Run the focused test to verify ranged Codex summary fields pass**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testDerivedDataUsesCodexDetailedBucketsForToday`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: derive detailed ranged codex summaries"
```

### Task 5: Keep Token Flow and Breakdowns Consistent

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulse/Managers/CodexUsageModels.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`
- Test: `pulseTests/AgentUsageViewDataTests.swift`

- [ ] **Step 1: Write failing tests for Codex model/provider breakdowns and token flow consistency**

```swift
func testCodexProviderBreakdownUsesDetailedBucketTotals() {
    XCTAssertEqual(data.providerBreakdown.first?.summary.totalTokens, 70)
}

func testAllSourceTokenFlowIncludesDetailedCodexBucketTotals() {
    XCTAssertEqual(flow.totalTokens, 70 + openCodeTokens)
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testAllSourceTokenFlowIncludesDetailedCodexBucketTotals -only-testing:pulseTests/AgentUsageViewDataTests/testCodexProviderBreakdownUsesDetailedBucketTotals`

Expected: FAIL because token flow and Codex breakdowns are not yet verified against the richer bucket model.

- [ ] **Step 3: Keep `CodexUsageSnapshot.makeSummary(from:)` as the single Codex summary normalizer**

```swift
func providerBreakdown(for scope: AgentScope) -> [ProviderBreakdown] {
    Dictionary(grouping: source) { $0.modelProvider }
        .compactMap { provider, sessions in
            ProviderBreakdown(provider: provider, summary: Self.makeSummary(from: sessions))
        }
        .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
}
```

- [ ] **Step 4: Keep all-source token flow sourced from daily buckets when available**

```swift
for bucket in state.codexDailyBuckets where bucket.day >= dayRange.lowerBound && bucket.day < dayRange.upperBound {
    totalsByDay[bucket.day, default: 0] += bucket.totalTokens
}
```

- [ ] **Step 5: Run the focused tests to verify breakdowns and chart totals pass**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests/testAllSourceTokenFlowIncludesDetailedCodexBucketTotals -only-testing:pulseTests/AgentUsageViewDataTests/testCodexProviderBreakdownUsesDetailedBucketTotals`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/Managers/CodexUsageModels.swift pulseTests/AgentUsageStoreTests.swift pulseTests/AgentUsageViewDataTests.swift
git commit -m "feat: align codex breakdowns with detailed bucket totals"
```

### Task 6: Full Verification and Version Bump

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/AgentUsageStoreTests.swift`
- Test: `pulseTests/AgentUsageViewDataTests.swift`

- [ ] **Step 1: Ensure the patch release version is bumped once for the bug fix**

```diff
- MARKETING_VERSION = 1.8.12;
+ MARKETING_VERSION = 1.8.13;
```

- [ ] **Step 2: Run the agent usage test slice**

Run: `xcodebuild test -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/AgentUsageViewDataTests`

Expected: PASS

- [ ] **Step 3: Run the required project build**

Run: `xcodebuild -project /Users/zyao/Desktop/pulse/pulse.xcodeproj -scheme pulse -configuration Debug build`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add pulse.xcodeproj/project.pbxproj pulse/Managers/CodexUsageModels.swift pulse/Managers/CodexUsageQuery.swift pulse/Managers/AgentUsageRepository.swift pulse/Managers/AgentUsageViewData.swift pulse/Managers/AgentUsageStore.swift pulseTests/AgentUsageStoreTests.swift pulseTests/AgentUsageViewDataTests.swift
git commit -m "fix: add detailed codex usage metrics"
```

## Self-Review

- Spec coverage: the plan covers native `total_tokens` preservation, detailed metric mapping, ranged snapshot reconstruction, missing-transcript handling, breakdown/chart consistency, and build verification.
- Placeholder scan: there are no `TODO` or “handle appropriately” steps; every code-changing step includes concrete snippets and every verification step includes exact commands.
- Type consistency: the plan consistently uses `CodexDailyBucket.totalTokens`, `CodexSessionRecord.tokensUsed`, and optional detailed fields on `CodexSessionRecord` to align with the existing normalized `AgentUsageSummary`.
