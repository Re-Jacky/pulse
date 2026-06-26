# Requests + Cache Hit Rate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add "Requests" metric card and "Hit Rate" summary pill to the Agent Usage tab.

**Architecture:** `requestCount` is added to daily bucket structs and populated during existing query iterations. For OpenCode, it also flows through `OpenCodeSessionRecord` via a SQL COUNT subquery. For Codex, `requestCount` is computed from daily buckets and injected into the summary at `derivedData` time (bypassing `CodexSessionRecord` which lacks the field). Cache hit rate is derived at view time from existing `cacheReadTokens / inputTokens`.

**Tech Stack:** Swift 5.9+, AppKit/SwiftUI, SQLite3, no external dependencies.

## Global Constraints

- `requestCount` defaults to 0 in all structs (backward compat with test fixtures)
- Cache hit rate = `cacheReadTokens / inputTokens`, displayed as percentage (e.g. "68%")
- Hit Rate pill hidden when `cacheReadTokens` is nil or `inputTokens` is nil/zero
- All SQLite opens must use URI form with `immutable=1`
- Use semantic colors from `pulse/Views/Colors.swift` — no hard-coded light/dark values

---

### Task 1: Add `requestCount` to data model structs

**Files:**
- Modify: `pulse/Managers/AgentUsageModels.swift:78-119` (AgentUsageSummary + merge)
- Modify: `pulse/Managers/OpenCodeUsageModels.swift:3-27` (OpenCodeSessionRecord)
- Modify: `pulse/Managers/OpenCodeDailyBucket.swift:3-44` (OpenCodeDailyBucket)
- Modify: `pulse/Managers/CodexUsageModels.swift:30-98` (CodexDailyBucket + merging + zero)

**Interfaces:**
- Produces: `AgentUsageSummary.requestCount: Int`, `OpenCodeSessionRecord.requestCount: Int`, `OpenCodeDailyBucket.requestCount: Int`, `CodexDailyBucket.requestCount: Int`

- [ ] **Step 1: Add `requestCount` to `AgentUsageSummary`**

In `pulse/Managers/AgentUsageModels.swift`, add `requestCount: Int` field with default value 0:

```swift
struct AgentUsageSummary: Equatable {
    let totalTokens: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let requestCount: Int
    let sessionsCount: Int
    let cost: Double?
    let lastUpdated: Date?
}
```

Update `merge` to include `requestCount: a.requestCount + b.requestCount`.

- [ ] **Step 2: Add `requestCount` to `OpenCodeSessionRecord`**

In `pulse/Managers/OpenCodeUsageModels.swift`, add `requestCount: Int` field:

```swift
struct OpenCodeSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let agent: String
    let modelProviderID: String
    let modelID: String
    let modelVariant: String?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let requestCount: Int
    let cost: Double
    let createdAt: Date
    let updatedAt: Date
    // ... computed properties unchanged
}
```

- [ ] **Step 3: Add `requestCount` to `OpenCodeDailyBucket`**

In `pulse/Managers/OpenCodeDailyBucket.swift`, add `requestCount: Int` to struct and init (default 0):

```swift
struct OpenCodeDailyBucket: Equatable {
    let sessionID: String
    let day: Int
    let modelProviderID: String
    let modelID: String
    let modelVariant: String?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let requestCount: Int
    let cost: Double
    let latestActivityAt: Date?

    init(
        sessionID: String,
        day: Int,
        modelProviderID: String = "",
        modelID: String = "",
        modelVariant: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        requestCount: Int = 0,
        cost: Double,
        latestActivityAt: Date? = nil
    ) {
        // ... assign all fields including self.requestCount = requestCount
    }
}
```

- [ ] **Step 4: Add `requestCount` to `CodexDailyBucket`**

In `pulse/Managers/CodexUsageModels.swift`, add `requestCount: Int` to struct, init, `zero()`, and `merging()`:

```swift
struct CodexDailyBucket: Equatable {
    let sessionID: String
    let day: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let latestActivityAt: Date?

    init(
        sessionID: String,
        day: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        requestCount: Int = 0,
        latestActivityAt: Date? = nil
    ) {
        // ... assign all fields including self.requestCount = requestCount
    }

    static func zero(sessionID: String, day: Int) -> CodexDailyBucket {
        CodexDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 0,
            requestCount: 0,
            latestActivityAt: nil
        )
    }

    func merging(_ other: CodexDailyBucket) -> CodexDailyBucket {
        // ... existing merge logic, add:
        // requestCount: requestCount + other.requestCount
    }
}
```

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5`

Expected: Build will fail due to callers not passing `requestCount` — this is expected at this step. We will fix callers in subsequent tasks. However, since defaults of 0 are provided, the build should succeed for most call sites. Verify and note any failures.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift pulse/Managers/OpenCodeUsageModels.swift pulse/Managers/OpenCodeDailyBucket.swift pulse/Managers/CodexUsageModels.swift
git commit -m "feat: add requestCount field to usage data model structs"
```

---

### Task 2: Populate `requestCount` in OpenCode queries

**Files:**
- Modify: `pulse/Managers/OpenCodeUsageStore.swift:92-195` (loadDailySnapshot)
- Modify: `pulse/Managers/OpenCodeUsageStore.swift:197-275` (loadSnapshot)
- Modify: `pulse/Managers/OpenCodeUsageStore.swift:277-379` (loadDailyBuckets)

**Interfaces:**
- Consumes: `OpenCodeSessionRecord.requestCount`, `OpenCodeDailyBucket.requestCount` (from Task 1)
- Produces: Query results with populated `requestCount`

- [ ] **Step 1: Add COUNT to `loadDailyBuckets` iteration**

In `pulse/Managers/OpenCodeUsageStore.swift`, in `loadDailyBuckets` (line 329), each row = one assistant message. Add `requestCount: 1` to the per-row `OpenCodeDailyBucket` init, and add `requestCount: (existing?.requestCount ?? 0) + 1` to the accumulation at line 357–370.

The per-row bucket init (line 329–342) becomes:
```swift
let bucket = OpenCodeDailyBucket(
    sessionID: sessionID,
    day: day,
    modelProviderID: stringColumn(statement, index: 2),
    modelID: stringColumn(statement, index: 3),
    modelVariant: optionalStringColumn(statement, index: 4),
    inputTokens: Int(sqlite3_column_int64(statement, 5)),
    outputTokens: Int(sqlite3_column_int64(statement, 6)),
    reasoningTokens: Int(sqlite3_column_int64(statement, 7)),
    cacheReadTokens: Int(sqlite3_column_int64(statement, 8)),
    cacheWriteTokens: Int(sqlite3_column_int64(statement, 9)),
    requestCount: 1,
    cost: sqlite3_column_double(statement, 10),
    latestActivityAt: createdAt
)
```

The accumulation (line 357–370) adds:
```swift
requestCount: (existing?.requestCount ?? 0) + 1,
```

- [ ] **Step 2: Add COUNT subquery to `loadSnapshot` SQL**

In `pulse/Managers/OpenCodeUsageStore.swift`, in `loadSnapshot` (line 211–230), add a subquery column to the SQL:

```sql
select
id,
title,
directory,
coalesce(agent, ''),
coalesce(json_extract(model, '$.providerID'), ''),
coalesce(json_extract(model, '$.id'), ''),
nullif(json_extract(model, '$.variant'), ''),
coalesce(tokens_input, 0),
coalesce(tokens_output, 0),
coalesce(tokens_reasoning, 0),
coalesce(tokens_cache_read, 0),
coalesce(tokens_cache_write, 0),
coalesce(cost, 0),
(select count(*) from message where message.session_id = session.id
 and json_extract(message.data, '$.role') = 'assistant') as request_count,
time_created,
time_updated
from session
order by time_updated desc
```

Read the new column (index 12, shifting cost to 12→read as double, time_created to 14, time_updated to 15 — or insert request_count between tokens_cache_write and cost to minimize shifting). The exact column position choice:

Insert after `tokens_cache_write` (index 11), before `cost`:
- Column 12: `request_count` → `Int(sqlite3_column_int64(statement, 12))`
- Column 13: `cost` → `sqlite3_column_double(statement, 13)`
- Column 14: `time_created` → shifts from 13 to 14
- Column 15: `time_updated` → shifts from 14 to 15

Update the session record construction:
```swift
requestCount: Int(sqlite3_column_int64(statement, 12)),
cost: sqlite3_column_double(statement, 13),
```

And date columns shift:
```swift
let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 14)) / 1000)
let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 15)) / 1000)
```

- [ ] **Step 3: Add COUNT to `loadDailySnapshot` SQL**

Same change in `loadDailySnapshot` (line 125–148). The query already joins `message` and groups by `s.id`. Add `COUNT(m.id) as request_count` to the SELECT list.

Insert after `SUM(coalesce(json_extract(m.data, '$.tokens.cache.write'), 0))`:
```sql
SUM(coalesce(json_extract(m.data, '$.tokens.cache.write'), 0)),
COUNT(m.id) as request_count,
SUM(coalesce(json_extract(m.data, '$.cost'), 0)),
MIN(s.time_created),
MAX(s.time_updated)
```

Column indices shift. Update `OpenCodeSessionRecord` construction to read `request_count` and adjust subsequent indices:
```swift
requestCount: Int(sqlite3_column_int64(statement, 11)),
cost: sqlite3_column_double(statement, 12),
```
And `createdAt`/`updatedAt` shift to columns 13, 14.

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: Build succeeds (or fails only in aggregation code not yet updated — fix any remaining issues).

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/OpenCodeUsageStore.swift
git commit -m "feat: populate requestCount in OpenCode SQL queries"
```

---

### Task 3: Populate `requestCount` in Codex bucket accumulation

**Files:**
- Modify: `pulse/Managers/CodexUsageQuery.swift:327-410` (accumulateDailyBuckets)
- Modify: `pulse/Managers/CodexUsageQuery.swift:170-209` (loadDailyBuckets)

**Interfaces:**
- Consumes: `CodexDailyBucket.requestCount` (from Task 1)
- Produces: `CodexDailyBucket` results with populated `requestCount`

- [ ] **Step 1: Increment requestCount in `accumulateDailyBuckets` per `token_count` event**

In `pulse/Managers/CodexUsageQuery.swift`, inside `accumulateDailyBuckets` (line 397–406), each `token_count` event creates a delta bucket. Add `requestCount: 1`:

```swift
let deltaBucket = CodexDailyBucket(
    sessionID: currentSessionID,
    day: day,
    inputTokens: deltaUsage.inputTokens,
    outputTokens: deltaUsage.outputTokens,
    reasoningTokens: deltaUsage.reasoningTokens,
    cacheReadTokens: deltaUsage.cacheReadTokens,
    totalTokens: deltaUsage.totalTokens,
    requestCount: 1,
    latestActivityAt: timestamp
)
```

Since `merging()` already sums `requestCount` (added in Task 1), the accumulation at line 408 (`existing.merging(deltaBucket)`) will correctly sum request counts.

- [ ] **Step 2: Pass `requestCount` through in `loadDailyBuckets` return**

In `loadDailyBuckets` (line 188–201), the `compactMap` constructs `CodexDailyBucket` from the merged buckets. Add `requestCount: bucket.requestCount`:

```swift
return CodexDailyBucket(
    sessionID: parts[0],
    day: day,
    inputTokens: bucket.inputTokens,
    outputTokens: bucket.outputTokens,
    reasoningTokens: bucket.reasoningTokens,
    cacheReadTokens: bucket.cacheReadTokens,
    totalTokens: bucket.totalTokens,
    requestCount: bucket.requestCount,
    latestActivityAt: bucket.latestActivityAt
)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add pulse/Managers/CodexUsageQuery.swift
git commit -m "feat: populate requestCount in Codex daily bucket accumulation"
```

---

### Task 4: Flow `requestCount` through aggregation and summary derivation

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift:353-389` (aggregatedSnapshot)
- Modify: `pulse/Managers/AgentUsageStore.swift:391-427` (aggregatedCodexSnapshot)
- Modify: `pulse/Managers/AgentUsageStore.swift:205-228` (derivedData — Codex bucket enrichment)
- Modify: `pulse/Managers/AgentUsageStore.swift:764-776` (replacingLastUpdated → also carry requestCount)
- Modify: `pulse/Managers/OpenCodeUsageModels.swift:178-189` (OpenCode makeSummary)
- Modify: `pulse/Managers/CodexUsageModels.swift:270-281` (Codex makeSummary)

**Interfaces:**
- Consumes: `requestCount` from bucket/record structs (Tasks 1–3)
- Produces: `AgentUsageSummary.requestCount` correctly populated for all sources/ranges

- [ ] **Step 1: Update `OpenCodeUsageSnapshot.makeSummary` to include `requestCount`**

In `pulse/Managers/OpenCodeUsageModels.swift:178-189`, add:

```swift
requestCount: sessions.reduce(0) { $0 + $1.requestCount },
```

- [ ] **Step 2: Update `CodexUsageSnapshot.makeSummary` to include `requestCount`**

In `pulse/Managers/CodexUsageModels.swift:270-281`, add:

```swift
requestCount: 0,
```

Codex request count is 0 here because `CodexSessionRecord` doesn't carry it. It gets enriched from buckets in `derivedData`.

- [ ] **Step 3: Update `aggregatedSnapshot` to carry `requestCount`**

In `pulse/Managers/AgentUsageStore.swift:353-389`, add to the `OpenCodeSessionRecord` construction:

```swift
requestCount: inRange.reduce(0) { $0 + $1.requestCount },
```

- [ ] **Step 4: Update `replacingLastUpdated` to carry `requestCount`**

In `pulse/Managers/AgentUsageStore.swift:764-776`, add `requestCount: summary.requestCount` to the reconstructed `AgentUsageSummary`.

- [ ] **Step 5: Add Codex `requestCount` enrichment in `derivedData`**

In `pulse/Managers/AgentUsageStore.swift:205-228`, after computing `baseSummary` but before `replacingLastUpdated`, compute the Codex request count from daily buckets:

Add a helper method:
```swift
private func codexRequestCountFromBuckets(
    for selection: AgentUsageSelection,
    scope: AgentScope
) -> Int {
    guard selection.source == .codex || selection.source == .all else { return 0 }
    let dayRange = agentUsageDayRange(for: selection.timeRange)
    var buckets = state.codexDailyBuckets.filter { $0.day >= dayRange.lowerBound && $0.day < dayRange.upperBound }

    switch scope {
    case .allProjects:
        break
    case .project(let directory):
        let sessionIDs = Set(state.codexSnapshot.sessions.filter { $0.cwd == directory }.map(\.id))
        buckets = buckets.filter { sessionIDs.contains($0.sessionID) }
    case .session(_, let sessionID):
        buckets = buckets.filter { $0.sessionID == sessionID }
    }

    return buckets.reduce(0) { $0 + $1.requestCount }
}
```

Then in `derivedData`, after computing `baseSummary`, enrich `requestCount`:

```swift
let enrichedRequestCount: Int = {
    switch selection.source {
    case .openCode:
        return baseSummary.requestCount
    case .codex:
        return codexRequestCountFromBuckets(for: selection, scope: scope)
    case .all:
        return baseSummary.requestCount + codexRequestCountFromBuckets(for: selection, scope: scope)
    }
}()
```

And modify the summary construction to use `enrichedRequestCount` instead of `baseSummary.requestCount`. This can be done by adding a `replacingRequestCount` helper, or by combining with `replacingLastUpdated`:

```swift
private func replacingRequestCount(in summary: AgentUsageSummary, with requestCount: Int) -> AgentUsageSummary {
    AgentUsageSummary(
        totalTokens: summary.totalTokens,
        inputTokens: summary.inputTokens,
        outputTokens: summary.outputTokens,
        reasoningTokens: summary.reasoningTokens,
        cacheReadTokens: summary.cacheReadTokens,
        cacheWriteTokens: summary.cacheWriteTokens,
        requestCount: requestCount,
        sessionsCount: summary.sessionsCount,
        cost: summary.cost,
        lastUpdated: summary.lastUpdated
    )
}
```

Then in `derivedData`:
```swift
let summary: AgentUsageSummary = {
    let baseSummary: AgentUsageSummary = switch selection.source { ... }
    let enriched = replacingRequestCount(in: baseSummary, with: enrichedRequestCount)
    return replacingLastUpdated(in: enriched, with: latestActivityDate(...))
}()
```

- [ ] **Step 6: Build to verify**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/Managers/OpenCodeUsageModels.swift pulse/Managers/CodexUsageModels.swift
git commit -m "feat: flow requestCount through aggregation and summary derivation"
```

---

### Task 5: Add "Requests" metric card and "Hit Rate" summary pill to the UI

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift:654-684` (buildUsageMetrics, buildSummaryPills)

**Interfaces:**
- Consumes: `AgentUsageSummary.requestCount`, `AgentUsageSummary.cacheReadTokens`, `AgentUsageSummary.inputTokens` (from Task 4)
- Produces: `usageMetrics` array with Requests card, `summaryPills` array with Hit Rate pill

- [ ] **Step 1: Add "Requests" metric card in `buildUsageMetrics`**

In `pulse/Managers/AgentUsageStore.swift:654-668`, after the Cache Read card append, add:

```swift
if summary.requestCount > 0 {
    metrics.append(AgentUsageMetricCard(id: "requests", title: "Requests", valueText: compact(summary.requestCount), detailText: nil))
}
```

- [ ] **Step 2: Add "Hit Rate" summary pill in `buildSummaryPills`**

In `pulse/Managers/AgentUsageStore.swift:670-684`, after the Cache Write pill, add:

```swift
if let cacheRead = summary.cacheReadTokens, let input = summary.inputTokens, input > 0 {
    let rate = Double(cacheRead) / Double(input)
    pills.append(AgentUsageSummaryPill(id: "hitRate", title: "Hit Rate", valueText: String(format: "%.0f%%", rate * 100)))
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift
git commit -m "feat: add Requests metric card and Hit Rate summary pill"
```

---

### Task 6: Fix test fixtures and add tests for new fields

**Files:**
- Modify: `pulseTests/AgentUsageViewDataTests.swift:246-303` (test helper functions, StubRepository)
- Modify: `pulseTests/AgentUsageStoreTests.swift` (all test helpers creating OpenCodeSessionRecord, OpenCodeDailyBucket, CodexDailyBucket, AgentUsageSummary)
- Modify: `pulseTests/AgentUsageViewDataTests.swift` (add new test for requestCount and hitRate)

**Interfaces:**
- Consumes: All new `requestCount` fields from Tasks 1–5

- [ ] **Step 1: Update test helper `makeOpenCodeSession` in AgentUsageViewDataTests**

Add `requestCount: 0` to the `OpenCodeSessionRecord` init call (line 246–264).

- [ ] **Step 2: Update test helper `makeCodexSession` in AgentUsageViewDataTests**

No change needed — `CodexSessionRecord` has no `requestCount` field.

- [ ] **Step 3: Update `StubRepository` if it creates any bucket/summary objects**

The stub returns empty arrays, so no change needed unless methods create `AgentUsageSummary` directly.

- [ ] **Step 4: Search for all `AgentUsageSummary(` constructor calls in tests and add `requestCount: 0`**

Run: `grep -rn "AgentUsageSummary(" pulseTests/`

Add `requestCount: 0` (or appropriate value) to each call site.

- [ ] **Step 5: Search for all `OpenCodeSessionRecord(` constructor calls in tests and add `requestCount: 0`**

Run: `grep -rn "OpenCodeSessionRecord(" pulseTests/`

Add `requestCount: 0` (or appropriate value) to each call site.

- [ ] **Step 6: Search for all `OpenCodeDailyBucket(` constructor calls in tests and add `requestCount: 0`**

Run: `grep -rn "OpenCodeDailyBucket(" pulseTests/`

Add `requestCount: 0` to each call site.

- [ ] **Step 7: Search for all `CodexDailyBucket(` constructor calls in tests and add `requestCount: 0`**

Run: `grep -rn "CodexDailyBucket(" pulseTests/`

Add `requestCount: 0` to each call site.

- [ ] **Step 8: Add test for requestCount enrichment from Codex daily buckets**

In `pulseTests/AgentUsageViewDataTests.swift`, add:

```swift
func testDerivedDataForCodexEnrichesRequestCountFromDailyBuckets() {
    let store = AgentUsageStore(repository: StubRepository())
    let now = Date()
    let todayDay = agentUsageDayIdentifier(for: now)
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
            openCodeDailyBuckets: [],
            codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "t1", tokens: 100)]),
            codexDailyBuckets: [
                CodexDailyBucket(
                    sessionID: "t1",
                    day: todayDay,
                    inputTokens: 80,
                    outputTokens: 20,
                    reasoningTokens: 0,
                    cacheReadTokens: 40,
                    totalTokens: 100,
                    requestCount: 5,
                    latestActivityAt: now
                )
            ],
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .codex,
        timeRange: .today,
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertEqual(data.summary.requestCount, 5)
}
```

- [ ] **Step 9: Add test for hit rate derivation**

In `pulseTests/AgentUsageViewDataTests.swift`, add:

```swift
func testBuildSummaryPillsIncludesHitRateWhenCacheReadAndInputAvailable() {
    let store = AgentUsageStore(repository: StubRepository())
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                OpenCodeSessionRecord(
                    id: "s1",
                    title: "Test",
                    directory: "/tmp",
                    agent: "build",
                    modelProviderID: "opencode",
                    modelID: "model-a",
                    modelVariant: nil,
                    inputTokens: 100,
                    outputTokens: 20,
                    reasoningTokens: 0,
                    cacheReadTokens: 60,
                    cacheWriteTokens: 0,
                    requestCount: 3,
                    cost: 0,
                    createdAt: Date(timeIntervalSince1970: 1000),
                    updatedAt: Date(timeIntervalSince1970: 2000)
                )
            ]),
            openCodeDailyBuckets: [],
            codexSnapshot: CodexUsageSnapshot(sessions: []),
            codexDailyBuckets: [],
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .openCode,
        timeRange: .allTime,
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    let hitRatePill = data.summaryPills.first { $0.id == "hitRate" }
    XCTAssertNotNil(hitRatePill)
    XCTAssertEqual(hitRatePill?.valueText, "60%")
}
```

- [ ] **Step 10: Add test for hit rate hidden when no cache data**

```swift
func testBuildSummaryPillsOmitsHitRateWhenNoCacheReadTokens() {
    let store = AgentUsageStore(repository: StubRepository())
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                OpenCodeSessionRecord(
                    id: "s1",
                    title: "Test",
                    directory: "/tmp",
                    agent: "build",
                    modelProviderID: "opencode",
                    modelID: "model-a",
                    modelVariant: nil,
                    inputTokens: 100,
                    outputTokens: 20,
                    reasoningTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    requestCount: 2,
                    cost: 0,
                    createdAt: Date(timeIntervalSince1970: 1000),
                    updatedAt: Date(timeIntervalSince1970: 2000)
                )
            ]),
            openCodeDailyBuckets: [],
            codexSnapshot: CodexUsageSnapshot(sessions: []),
            codexDailyBuckets: [],
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .openCode,
        timeRange: .allTime,
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    let hitRatePill = data.summaryPills.first { $0.id == "hitRate" }
    XCTAssertNil(hitRatePill)
}
```

- [ ] **Step 11: Add test for Requests metric card**

```swift
func testBuildUsageMetricsIncludesRequestsCard() {
    let store = AgentUsageStore(repository: StubRepository())
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                OpenCodeSessionRecord(
                    id: "s1",
                    title: "Test",
                    directory: "/tmp",
                    agent: "build",
                    modelProviderID: "opencode",
                    modelID: "model-a",
                    modelVariant: nil,
                    inputTokens: 100,
                    outputTokens: 0,
                    reasoningTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    requestCount: 15,
                    cost: 0,
                    createdAt: Date(timeIntervalSince1970: 1000),
                    updatedAt: Date(timeIntervalSince1970: 2000)
                )
            ]),
            openCodeDailyBuckets: [],
            codexSnapshot: CodexUsageSnapshot(sessions: []),
            codexDailyBuckets: [],
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .openCode,
        timeRange: .allTime,
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    let requestsCard = data.usageMetrics.first { $0.id == "requests" }
    XCTAssertNotNil(requestsCard)
    XCTAssertEqual(requestsCard?.title, "Requests")
}
```

- [ ] **Step 12: Run tests**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 13: Commit**

```bash
git add pulseTests/AgentUsageViewDataTests.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "test: add requestCount fields to test fixtures and tests for requests + hit rate"
```

---

### Task 7: Final build verification

**Files:** None (verification only)

- [ ] **Step 1: Full clean build**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug clean build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 3: Commit if any fixups were needed**
