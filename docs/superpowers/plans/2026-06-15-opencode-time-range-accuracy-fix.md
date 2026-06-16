# OpenCode Time-Range Accuracy Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct OpenCode token totals for Today, 7 Days, and 30 Days by aggregating from per-message daily-bucketed data instead of cumulative session columns.

**Architecture:** At refresh time, load both the cumulative snapshot (All Time) and per-day per-session token buckets from the message table. On time-range change, aggregate buckets into an `OpenCodeUsageSnapshot` in memory. No SQL on selection changes.

**Tech Stack:** Swift, AppKit/SwiftUI, SQLite3 (via `sqlite3.h` directly)

---

### Task 1: Create `OpenCodeDailyBucket` model + query method

**Files:**
- Create: `pulse/Managers/OpenCodeDailyBucket.swift`
- Modify: `pulse/Managers/OpenCodeUsageStore.swift` (add `loadDailyBuckets`)
- Test: `pulseTests/OpenCodeUsageStoreTests.swift` (add bucket query test)

- [ ] **Step 1: Create the `OpenCodeDailyBucket` model**

```swift
import Foundation

struct OpenCodeDailyBucket: Equatable {
    let sessionID: String
    let day: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cost: Double
}
```

- [ ] **Step 2: Add `loadDailyBuckets` query to `OpenCodeUsageQuery`**

Add to `OpenCodeUsageStore.swift`, inside the `OpenCodeUsageQuery` enum, after `loadSnapshot`:

```swift
static func loadDailyBuckets(databaseURL: URL) throws -> [OpenCodeDailyBucket] {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
        throw QueryError.databaseNotFound(path: databaseURL.path)
    }

    let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw QueryError.databaseOpenFailed(message: message)
    }
    defer { sqlite3_close(db) }

    let sql = """
    SELECT m.session_id,
           (m.time_created / 86400000) AS day,
           SUM(coalesce(json_extract(m.data, '$.tokens.input'), 0)),
           SUM(coalesce(json_extract(m.data, '$.tokens.output'), 0)),
           SUM(coalesce(json_extract(m.data, '$.tokens.reasoning'), 0)),
           SUM(coalesce(json_extract(m.data, '$.tokens.cache.read'), 0)),
           SUM(coalesce(json_extract(m.data, '$.tokens.cache.write'), 0)),
           SUM(coalesce(json_extract(m.data, '$.cost'), 0))
    FROM message m
    WHERE json_extract(m.data, '$.role') = 'assistant'
    GROUP BY m.session_id, day
    ORDER BY m.session_id, day
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var buckets: [OpenCodeDailyBucket] = []

    while true {
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { break }
        guard stepResult == SQLITE_ROW else {
            throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        buckets.append(
            OpenCodeDailyBucket(
                sessionID: stringColumn(statement, index: 0),
                day: Int(sqlite3_column_int64(statement, 1)),
                inputTokens: Int(sqlite3_column_int64(statement, 2)),
                outputTokens: Int(sqlite3_column_int64(statement, 3)),
                reasoningTokens: Int(sqlite3_column_int64(statement, 4)),
                cacheReadTokens: Int(sqlite3_column_int64(statement, 5)),
                cacheWriteTokens: Int(sqlite3_column_int64(statement, 6)),
                cost: sqlite3_column_double(statement, 7)
            )
        )
    }

    return buckets
}
```

- [ ] **Step 3: Write test for `loadDailyBuckets`**

Add to `OpenCodeUsageStoreTests.swift` inside the `OpenCodeUsageQueryTests` class, before the `private` helpers:

```swift
func testLoadDailyBucketsReturnsPerSessionPerDayTokens() throws {
    let databaseURL = try makeDatabase(named: "DailyBucketTests.sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }

    let db = try openWritableDatabase(databaseURL)
    defer { sqlite3_close(db) }

    try execute(db, sql: """
    create table session (
        id text primary key, project_id text not null, title text not null,
        directory text not null, agent text, model text,
        cost real default 0 not null,
        tokens_input integer default 0 not null,
        tokens_output integer default 0 not null,
        tokens_reasoning integer default 0 not null,
        tokens_cache_read integer default 0 not null,
        tokens_cache_write integer default 0 not null,
        time_created integer not null, time_updated integer not null
    );
    """)

    try execute(db, sql: """
    create table message (
        id text primary key, session_id text not null,
        time_created integer not null, time_updated integer not null, data text not null
    );
    """)

    try execute(db, sql: """
    insert into session (id, project_id, title, directory, cost,
        tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
        time_created, time_updated)
    values ('ses_1', 'p1', 'Test', '/tmp/test', 0, 0, 0, 0, 0, 0, 1000, 2000);
    """)

    try execute(db, sql: """
    insert into message (id, session_id, time_created, time_updated, data) values
    ('msg_1', 'ses_1', 172800000, 172800000,
     '{"role":"assistant","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":1000,"write":4}},"cost":0.02,"time":{"created":172800000}}'),
    ('msg_2', 'ses_1', 172800000, 172800000,
     '{"role":"assistant","tokens":{"input":200,"output":30,"reasoning":5,"cache":{"read":500,"write":2}},"cost":0.01,"time":{"created":172800000}}'),
    ('msg_3', 'ses_1', 259200000, 259200000,
     '{"role":"assistant","tokens":{"input":50,"output":20,"reasoning":0,"cache":{"read":200,"write":0}},"cost":0.005,"time":{"created":259200000}}');
    """)

    let buckets = try OpenCodeUsageQuery.loadDailyBuckets(databaseURL: databaseURL)

    XCTAssertEqual(buckets.count, 2)

    let day1 = buckets.first { $0.day == 172800000 / 86400000 }
    let day2 = buckets.first { $0.day == 259200000 / 86400000 }

    XCTAssertNotNil(day1)
    XCTAssertEqual(day1?.sessionID, "ses_1")
    XCTAssertEqual(day1?.inputTokens, 300)
    XCTAssertEqual(day1?.outputTokens, 80)
    XCTAssertEqual(day1?.reasoningTokens, 15)
    XCTAssertEqual(day1?.cacheReadTokens, 1500)
    XCTAssertEqual(day1?.cacheWriteTokens, 6)
    XCTAssertEqual(day1?.cost, 0.03, accuracy: 0.001)

    XCTAssertNotNil(day2)
    XCTAssertEqual(day2?.sessionID, "ses_1")
    XCTAssertEqual(day2?.inputTokens, 50)
    XCTAssertEqual(day2?.cacheReadTokens, 200)
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug test 2>&1 | tail -20`
Expected: Compile error — `OpenCodeDailyBucket` type not found or `loadDailyBuckets` not defined

- [ ] **Step 5: Create the file and query, then re-run**

Create `pulse/Managers/OpenCodeDailyBucket.swift` with the struct. Add the `loadDailyBuckets` method to `OpenCodeUsageQuery`. Then run test again.

Expected: `testLoadDailyBucketsReturnsPerSessionPerDayTokens` PASS

- [ ] **Step 6: Add `OpenCodeDailyBucket.swift` to Xcode project**

```bash
ruby add_files.rb pulse/Managers/OpenCodeDailyBucket.swift
```
Then verify build compiles.

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/OpenCodeDailyBucket.swift pulse/Managers/OpenCodeUsageStore.swift pulseTests/OpenCodeUsageStoreTests.swift
git commit -m "feat: add OpenCodeDailyBucket model and loadDailyBuckets query"
```

---

### Task 2: Add `openCodeDailyBuckets` to `AgentUsageLoadedState`

**Files:**
- Modify: `pulse/Managers/AgentUsageViewData.swift`

- [ ] **Step 1: Write the failing test**

Add to `AgentUsageStoreTests.swift` before the `makeOpenCodeSession` helper:

```swift
func testLoadedStateHoldsDailyBuckets() {
    let buckets = [OpenCodeDailyBucket(sessionID: "s1", day: 20000,
        inputTokens: 100, outputTokens: 50, reasoningTokens: 10,
        cacheReadTokens: 1000, cacheWriteTokens: 4, cost: 0.02)]
    let state = AgentUsageLoadedState(
        openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
        openCodeDailyBuckets: buckets,
        codexSnapshot: CodexUsageSnapshot(sessions: []),
        refreshGeneration: 0,
        codexDetailCache: [:]
    )
    XCTAssertEqual(state.openCodeDailyBuckets.count, 1)
    XCTAssertEqual(state.openCodeDailyBuckets[0].sessionID, "s1")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run test. Expected: Compile error — `openCodeDailyBuckets` not a member of `AgentUsageLoadedState`, and `AgentUsageLoadedState` initializer doesn't accept `openCodeDailyBuckets`.

- [ ] **Step 3: Modify `AgentUsageLoadedState`**

In `pulse/Managers/AgentUsageViewData.swift`, replace the existing struct:

```swift
struct AgentUsageLoadedState: Equatable {
    let openCodeCumulativeSnapshot: OpenCodeUsageSnapshot
    let openCodeDailyBuckets: [OpenCodeDailyBucket]
    let codexSnapshot: CodexUsageSnapshot
    let refreshGeneration: Int
    let codexDetailCache: [String: CodexSessionDetailState]

    static let empty = AgentUsageLoadedState(
        openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
        openCodeDailyBuckets: [],
        codexSnapshot: CodexUsageSnapshot(sessions: []),
        refreshGeneration: 0,
        codexDetailCache: [:]
    )
}
```

- [ ] **Step 4: Update all call sites that construct `AgentUsageLoadedState`**

In `pulse/Managers/AgentUsageStore.swift`, find every `AgentUsageLoadedState(` constructor and add `openCodeDailyBuckets:`. There are 4 sites:

Line ~52 (in `refreshAll`):
```swift
state = AgentUsageLoadedState(
    openCodeCumulativeSnapshot: previousState.openCodeCumulativeSnapshot,
    openCodeDailyBuckets: previousState.openCodeDailyBuckets,
    codexSnapshot: previousState.codexSnapshot,
    refreshGeneration: previousState.refreshGeneration,
    codexDetailCache: [:]
)
```

Line ~63 (in `refreshAll`, success path):
```swift
state = AgentUsageLoadedState(
    openCodeCumulativeSnapshot: openCodeSnapshot,
    openCodeDailyBuckets: dailyBuckets,
    codexSnapshot: codexSnapshot,
    refreshGeneration: nextGeneration,
    codexDetailCache: [:]
)
```

Lines ~93 and ~107 (in `ensureCodexDetailLoaded`):
```swift
// Replace state.openCodeSnapshot → state.openCodeCumulativeSnapshot in both blocks
state = AgentUsageLoadedState(
    openCodeCumulativeSnapshot: state.openCodeCumulativeSnapshot,
    openCodeDailyBuckets: state.openCodeDailyBuckets,
    codexSnapshot: state.codexSnapshot,
    refreshGeneration: state.refreshGeneration,
    codexDetailCache: nextCache
)
```

- [ ] **Step 5: Rename all references to `state.openCodeSnapshot` to `state.openCodeCumulativeSnapshot`**

In `AgentUsageStore.swift`, replace every `state.openCodeSnapshot` → `state.openCodeCumulativeSnapshot`. This affects lines in `derivedData`, `buildProjectOptions`, `totalTokensForProject`, `buildSessionOptions`, `buildTokenFlowData`, `buildContextRows`, `selectedOpenCodeSession`, `providerBreakdown`, `modelBreakdownRows`.

Use `replaceAll`:
```swift
state.openCodeSnapshot. → state.openCodeCumulativeSnapshot.
```

- [ ] **Step 6: Run tests to verify it passes**

Run test. Expected: `testLoadedStateHoldsDailyBuckets` PASS, existing tests PASS.

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/AgentUsageViewData.swift pulse/Managers/AgentUsageStore.swift
git commit -m "refactor: rename openCodeSnapshot to openCodeCumulativeSnapshot, add dailyBuckets to state"
```

---

### Task 3: Update `AgentUsageRepository` protocol and implementation

**Files:**
- Modify: `pulse/Managers/AgentUsageRepository.swift`
- Modify: `pulseTests/AgentUsageStoreTests.swift` (update stub)

- [ ] **Step 1: Write the failing test**

Add to `AgentUsageStoreTests.swift` before `makeOpenCodeSession`:

```swift
func testRepositoryLoadsDailyBuckets() throws {
    let repository = StubAgentUsageRepository()
    let buckets = repository.openCodeDailyBuckets
    XCTAssertEqual(buckets.count, 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: Compile error — `openCodeDailyBuckets` not in `StubAgentUsageRepository`.

- [ ] **Step 3: Update protocol and repository**

In `pulse/Managers/AgentUsageRepository.swift`, add to protocol:

```swift
protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket]
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail
}
```

In `AgentUsageRepository`:

```swift
struct AgentUsageRepository: AgentUsageRepositorying {
    // ... existing properties

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot {
        try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
    }

    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] {
        try OpenCodeUsageQuery.loadDailyBuckets(databaseURL: openCodeDatabaseURL)
    }

    func loadCodexSnapshot() throws -> CodexUsageSnapshot { ... }
    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail { ... }
}
```
