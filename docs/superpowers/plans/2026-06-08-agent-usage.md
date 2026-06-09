# Agent Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional OpenCode-backed Agent Usage feature to Pulse with a Settings toggle, conditional Agent tab, global/project/session token analysis, searchable selectors, and manual refresh.

**Architecture:** `AppDelegate` owns two new observable objects: one persisted settings manager for the Agent Usage feature flag and one OpenCode usage store that loads a read-only snapshot from the local OpenCode SQLite database. The main panel keeps the existing AppKit shell, while a new SwiftUI `AgentUsageView` renders the scope-sensitive summary, searchable project/session selectors, detailed token breakdown, and by-model rollups from the store's derived snapshot.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine, SQLite3, Foundation, Xcode project `pulse.xcodeproj`, `pulseTests` target.

---

## File Map

- Create: `pulse/Managers/AgentUsageSettings.swift`
  - Persist the `Agent Usage` feature toggle in `UserDefaults` and expose an observable `isEnabled` property.
- Create: `pulse/Managers/OpenCodeUsageModels.swift`
  - Define the session record, scope summary, project option, session option, and model breakdown types plus derived aggregation helpers.
- Create: `pulse/Managers/OpenCodeUsageStore.swift`
  - Load OpenCode data from `~/.local/share/opencode/opencode.db` with a read-only SQLite connection, publish loading/error state, and expose scope-ready snapshot data.
- Create: `pulse/Views/AgentUsageView.swift`
  - Render the Agent tab content, summary cards, detail section, by-model section, and refresh behavior.
- Create: `pulse/Views/SearchableSelectorView.swift`
  - Reusable SwiftUI selector control with a popover search field and ranked option list for projects and sessions.
- Create: `pulseTests/OpenCodeUsageModelsTests.swift`
  - Unit tests for token totals, project ranking, session sorting, scope summaries, and model aggregation.
- Create: `pulseTests/OpenCodeUsageStoreTests.swift`
  - SQLite-backed tests for loading a minimal OpenCode-style database snapshot and error handling.
- Modify: `pulse/App/AppDelegate.swift`
  - Own and inject the new settings/store objects, resize the panel when the feature is enabled, and keep open windows in sync with the feature toggle.
- Modify: `pulse/Views/PopoverView.swift`
  - Gate the third tab, sanitize persisted tab selection, and embed `AgentUsageView`.
- Modify: `pulse/Views/SettingsView.swift`
  - Add the `Agent Usage` section and toggle alongside the existing Theme section.
- Modify: `pulse.xcodeproj/project.pbxproj`
  - Add the new Swift source files and test files to the app/test targets, and bump `MARKETING_VERSION` from `1.3.1` to `1.4.0`.

## Notes Before Implementation

- Follow the repo rule that long-lived observable objects are owned by `AppDelegate` and passed down via `.environmentObject`; do not introduce `@StateObject` in views.
- Use the OpenCode SQLite database as the source of truth instead of the `opencode` CLI.
- Open the SQLite file with a URI such as `file:/Users/.../opencode.db?mode=ro&immutable=1` and `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` to avoid writing checkpoints or depending on WAL mutability.
- Keep the Agent-enabled panel wider than the current panel, but do not create a desktop-style analytics window.

### Task 1: Add failing tests for aggregation and formatting

**Files:**
- Create: `pulseTests/OpenCodeUsageModelsTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the new failing test file**

Create `pulseTests/OpenCodeUsageModelsTests.swift` with:

```swift
import XCTest
@testable import pulse

final class OpenCodeUsageModelsTests: XCTestCase {
    func testSessionTotalTokensAddsEveryTokenBucket() {
        let session = OpenCodeSessionRecord(
            id: "ses_1",
            title: "Agent feature",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "deepseek-v4-flash-free",
            modelVariant: "default",
            inputTokens: 120,
            outputTokens: 30,
            reasoningTokens: 8,
            cacheReadTokens: 400,
            cacheWriteTokens: 16,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(session.totalTokens, 574)
    }

    func testProjectOptionsAreRankedByTotalTokensDescending() {
        let low = OpenCodeSessionRecord(
            id: "ses_low",
            title: "Low",
            directory: "/Users/zyao/Desktop/low-project",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "model-a",
            modelVariant: nil,
            inputTokens: 10,
            outputTokens: 10,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let high = OpenCodeSessionRecord(
            id: "ses_high",
            title: "High",
            directory: "/Users/zyao/Desktop/high-project",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "model-b",
            modelVariant: nil,
            inputTokens: 100,
            outputTokens: 50,
            reasoningTokens: 10,
            cacheReadTokens: 500,
            cacheWriteTokens: 0,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4)
        )

        let snapshot = OpenCodeUsageSnapshot(sessions: [low, high])

        XCTAssertEqual(snapshot.projectOptions.map(\.shortName), ["high-project", "low-project"])
    }

    func testModelBreakdownAggregatesByProviderModelAndVariant() {
        let a = OpenCodeSessionRecord(
            id: "ses_a",
            title: "A",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "build",
            modelProviderID: "github-copilot",
            modelID: "claude-sonnet-4.6",
            modelVariant: "default",
            inputTokens: 200,
            outputTokens: 20,
            reasoningTokens: 0,
            cacheReadTokens: 1000,
            cacheWriteTokens: 0,
            cost: 1.5,
            createdAt: Date(timeIntervalSince1970: 5),
            updatedAt: Date(timeIntervalSince1970: 6)
        )

        let b = OpenCodeSessionRecord(
            id: "ses_b",
            title: "B",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "general",
            modelProviderID: "github-copilot",
            modelID: "claude-sonnet-4.6",
            modelVariant: "default",
            inputTokens: 100,
            outputTokens: 10,
            reasoningTokens: 0,
            cacheReadTokens: 200,
            cacheWriteTokens: 0,
            cost: 0.5,
            createdAt: Date(timeIntervalSince1970: 7),
            updatedAt: Date(timeIntervalSince1970: 8)
        )

        let snapshot = OpenCodeUsageSnapshot(sessions: [a, b])
        let breakdown = snapshot.modelBreakdown(for: .allProjects)

        XCTAssertEqual(breakdown.count, 1)
        XCTAssertEqual(breakdown[0].providerID, "github-copilot")
        XCTAssertEqual(breakdown[0].modelID, "claude-sonnet-4.6")
        XCTAssertEqual(breakdown[0].variant, "default")
        XCTAssertEqual(breakdown[0].summary.totalTokens, 1530)
        XCTAssertEqual(breakdown[0].summary.cost, 2.0, accuracy: 0.0001)
    }

    func testSessionScopeSummaryUsesOnlySelectedSession() {
        let one = OpenCodeSessionRecord(
            id: "ses_1",
            title: "One",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "model-a",
            modelVariant: nil,
            inputTokens: 20,
            outputTokens: 5,
            reasoningTokens: 1,
            cacheReadTokens: 100,
            cacheWriteTokens: 2,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 12)
        )

        let two = OpenCodeSessionRecord(
            id: "ses_2",
            title: "Two",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "general",
            modelProviderID: "opencode",
            modelID: "model-b",
            modelVariant: nil,
            inputTokens: 999,
            outputTokens: 999,
            reasoningTokens: 999,
            cacheReadTokens: 999,
            cacheWriteTokens: 999,
            cost: 9,
            createdAt: Date(timeIntervalSince1970: 13),
            updatedAt: Date(timeIntervalSince1970: 14)
        )

        let snapshot = OpenCodeUsageSnapshot(sessions: [one, two])
        let summary = snapshot.summary(for: .session(projectDirectory: "/Users/zyao/Desktop/pulse", sessionID: "ses_1"))

        XCTAssertEqual(summary.totalTokens, 128)
        XCTAssertEqual(summary.inputTokens, 20)
        XCTAssertEqual(summary.outputTokens, 5)
        XCTAssertEqual(summary.reasoningTokens, 1)
        XCTAssertEqual(summary.cacheReadTokens, 100)
        XCTAssertEqual(summary.cacheWriteTokens, 2)
        XCTAssertEqual(summary.sessionsCount, 1)
    }
}
```

- [ ] **Step 2: Add the test file to the Xcode project**

Update `pulse.xcodeproj/project.pbxproj` so `pulseTests/OpenCodeUsageModelsTests.swift` is referenced in the `pulseTests` group and added to the `pulseTests` Sources build phase.

- [ ] **Step 3: Run the new test to verify RED**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeUsageModelsTests
```

Expected: FAIL because `OpenCodeSessionRecord`, `OpenCodeUsageSnapshot`, and `OpenCodeScope` do not exist yet.

- [ ] **Step 4: Commit the failing model tests**

```bash
git add pulseTests/OpenCodeUsageModelsTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "test: add agent usage model tests"
```

### Task 2: Implement the settings object and pure usage models

**Files:**
- Create: `pulse/Managers/AgentUsageSettings.swift`
- Create: `pulse/Managers/OpenCodeUsageModels.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/OpenCodeUsageModelsTests.swift`

- [ ] **Step 1: Add the persisted feature settings object**

Create `pulse/Managers/AgentUsageSettings.swift` with:

```swift
import Foundation
import Combine

final class AgentUsageSettings: ObservableObject {
    static let userDefaultsKey = "agentUsageEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        isEnabled = userDefaults.object(forKey: Self.userDefaultsKey) as? Bool ?? false
    }
}
```

- [ ] **Step 2: Add the usage model file with the types used by the tests**

Create `pulse/Managers/OpenCodeUsageModels.swift` with:

```swift
import Foundation

enum OpenCodeScope: Equatable {
    case allProjects
    case project(directory: String)
    case session(projectDirectory: String, sessionID: String)
}

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
    let cost: Double
    let createdAt: Date
    let updatedAt: Date

    var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheWriteTokens
    }

    var shortProjectName: String {
        URL(fileURLWithPath: directory).lastPathComponent
    }
}

struct OpenCodeUsageSummary: Equatable {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let sessionsCount: Int
    let cost: Double
    let lastUpdated: Date?
}

struct OpenCodeProjectOption: Identifiable, Equatable {
    let id: String
    let directory: String
    let shortName: String
    let summary: OpenCodeUsageSummary
}

struct OpenCodeSessionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let agent: String
    let modelDisplayName: String
    let summary: OpenCodeUsageSummary
    let updatedAt: Date
}

struct OpenCodeModelBreakdown: Identifiable, Equatable {
    var id: String { [providerID, modelID, variant ?? ""].joined(separator: "::") }
    let providerID: String
    let modelID: String
    let variant: String?
    let summary: OpenCodeUsageSummary
}

struct OpenCodeUsageSnapshot: Equatable {
    let sessions: [OpenCodeSessionRecord]

    init(sessions: [OpenCodeSessionRecord]) {
        self.sessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    var projectOptions: [OpenCodeProjectOption] {
        Dictionary(grouping: sessions, by: \.directory)
            .map { directory, sessions in
                OpenCodeProjectOption(
                    id: directory,
                    directory: directory,
                    shortName: URL(fileURLWithPath: directory).lastPathComponent,
                    summary: OpenCodeUsageSnapshot.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.shortName.localizedCaseInsensitiveCompare(rhs.shortName) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func sessionOptions(for directory: String) -> [OpenCodeSessionOption] {
        sessions
            .filter { $0.directory == directory }
            .map { session in
                OpenCodeSessionOption(
                    id: session.id,
                    title: session.title,
                    directory: session.directory,
                    agent: session.agent,
                    modelDisplayName: OpenCodeUsageSnapshot.modelDisplayName(
                        providerID: session.modelProviderID,
                        modelID: session.modelID,
                        variant: session.modelVariant
                    ),
                    summary: OpenCodeUsageSnapshot.makeSummary(from: [session]),
                    updatedAt: session.updatedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func summary(for scope: OpenCodeScope) -> OpenCodeUsageSummary {
        switch scope {
        case .allProjects:
            return Self.makeSummary(from: sessions)
        case .project(let directory):
            return Self.makeSummary(from: sessions.filter { $0.directory == directory })
        case .session(_, let sessionID):
            return Self.makeSummary(from: sessions.filter { $0.id == sessionID })
        }
    }

    func modelBreakdown(for scope: OpenCodeScope) -> [OpenCodeModelBreakdown] {
        let source: [OpenCodeSessionRecord]
        switch scope {
        case .allProjects:
            source = sessions
        case .project(let directory):
            source = sessions.filter { $0.directory == directory }
        case .session:
            return []
        }

        return Dictionary(grouping: source) { session in
            [session.modelProviderID, session.modelID, session.modelVariant ?? ""].joined(separator: "::")
        }
        .compactMap { _, sessions in
            guard let first = sessions.first else { return nil }
            return OpenCodeModelBreakdown(
                providerID: first.modelProviderID,
                modelID: first.modelID,
                variant: first.modelVariant,
                summary: Self.makeSummary(from: sessions)
            )
        }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
    }

    static func makeSummary(from sessions: [OpenCodeSessionRecord]) -> OpenCodeUsageSummary {
        OpenCodeUsageSummary(
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            inputTokens: sessions.reduce(0) { $0 + $1.inputTokens },
            outputTokens: sessions.reduce(0) { $0 + $1.outputTokens },
            reasoningTokens: sessions.reduce(0) { $0 + $1.reasoningTokens },
            cacheReadTokens: sessions.reduce(0) { $0 + $1.cacheReadTokens },
            cacheWriteTokens: sessions.reduce(0) { $0 + $1.cacheWriteTokens },
            sessionsCount: sessions.count,
            cost: sessions.reduce(0) { $0 + $1.cost },
            lastUpdated: sessions.map(\.updatedAt).max()
        )
    }

    static func modelDisplayName(providerID: String, modelID: String, variant: String?) -> String {
        guard let variant, variant.isEmpty == false else {
            return "\(providerID) / \(modelID)"
        }

        return "\(providerID) / \(modelID) (\(variant))"
    }
}
```

- [ ] **Step 3: Add the new source files to the app target**

Update `pulse.xcodeproj/project.pbxproj` so `AgentUsageSettings.swift` and `OpenCodeUsageModels.swift` are in the `Managers` group and the app target Sources build phase.

- [ ] **Step 4: Run the model tests to verify GREEN**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeUsageModelsTests
```

Expected: PASS.

- [ ] **Step 5: Commit the settings and model layer**

```bash
git add pulse/Managers/AgentUsageSettings.swift pulse/Managers/OpenCodeUsageModels.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent usage settings and models"
```

### Task 3: Add failing SQLite loader tests

**Files:**
- Create: `pulseTests/OpenCodeUsageStoreTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the SQLite-backed failing tests**

Create `pulseTests/OpenCodeUsageStoreTests.swift` with:

```swift
import XCTest
import SQLite3
@testable import pulse

final class OpenCodeUsageStoreTests: XCTestCase {
    func testLoadSnapshotReadsSessionRowsAndParsesModelJSON() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeUsageStoreTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try execute(db, sql: """
        create table session (
            id text primary key,
            project_id text not null,
            title text not null,
            directory text not null,
            agent text,
            model text,
            cost real default 0 not null,
            tokens_input integer default 0 not null,
            tokens_output integer default 0 not null,
            tokens_reasoning integer default 0 not null,
            tokens_cache_read integer default 0 not null,
            tokens_cache_write integer default 0 not null,
            time_created integer not null,
            time_updated integer not null
        );
        """)

        try execute(db, sql: """
        insert into session (
            id, project_id, title, directory, agent, model, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            time_created, time_updated
        ) values (
            'ses_1', 'project_1', 'Pulse agent work', '/Users/zyao/Desktop/pulse', 'build',
            '{"id":"gpt-5.4","providerID":"codex-gpt","variant":"default"}',
            1.25, 100, 50, 10, 1000, 4, 1000, 2000
        );
        """)

        let snapshot = try OpenCodeUsageStore.loadSnapshot(databaseURL: databaseURL)

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].modelProviderID, "codex-gpt")
        XCTAssertEqual(snapshot.sessions[0].modelID, "gpt-5.4")
        XCTAssertEqual(snapshot.sessions[0].modelVariant, "default")
        XCTAssertEqual(snapshot.summary(for: .allProjects).totalTokens, 1164)
    }

    func testLoadSnapshotThrowsMissingDatabaseError() {
        let missingURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).sqlite")

        XCTAssertThrowsError(try OpenCodeUsageStore.loadSnapshot(databaseURL: missingURL)) { error in
            guard case OpenCodeUsageStore.LoadError.databaseNotFound(let path) = error else {
                return XCTFail("Unexpected error: \\(error)")
            }

            XCTAssertEqual(path, missingURL.path)
        }
    }

    private func makeDatabase(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func openWritableDatabase(_ url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeUsageStoreTests", code: 1)
        }
        return db
    }

    private func execute(_ db: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeUsageStoreTests", code: 2)
        }
    }
}
```

- [ ] **Step 2: Add the loader test file to the Xcode project**

Update `pulse.xcodeproj/project.pbxproj` so `pulseTests/OpenCodeUsageStoreTests.swift` is in the `pulseTests` group and test target Sources phase.

- [ ] **Step 3: Run the store test to verify RED**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeUsageStoreTests
```

Expected: FAIL because `OpenCodeUsageStore` and `OpenCodeUsageStore.LoadError` do not exist yet.

- [ ] **Step 4: Commit the failing store tests**

```bash
git add pulseTests/OpenCodeUsageStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "test: add OpenCode usage store tests"
```

### Task 4: Implement the OpenCode SQLite loader and published store

**Files:**
- Create: `pulse/Managers/OpenCodeUsageStore.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/OpenCodeUsageStoreTests.swift`

- [ ] **Step 1: Add the store with read-only snapshot loading**

Create `pulse/Managers/OpenCodeUsageStore.swift` with:

```swift
import Foundation
import Combine
import SQLite3

final class OpenCodeUsageStore: ObservableObject {
    enum LoadError: Error, Equatable, LocalizedError {
        case databaseNotFound(path: String)
        case databaseOpenFailed(message: String)
        case queryPrepareFailed(message: String)
        case queryStepFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let path):
                return "OpenCode database not found at \(path)"
            case .databaseOpenFailed(let message):
                return "Failed to open OpenCode database: \(message)"
            case .queryPrepareFailed(let message):
                return "Failed to prepare OpenCode query: \(message)"
            case .queryStepFailed(let message):
                return "Failed to read OpenCode rows: \(message)"
            }
        }
    }

    @Published private(set) var snapshot = OpenCodeUsageSnapshot(sessions: [])
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: LoadError?
    @Published private(set) var hasLoaded = false

    let databaseURL: URL

    init(databaseURL: URL = OpenCodeUsageStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
    }

    func refresh() {
        let firstLoad = hasLoaded == false
        if firstLoad {
            isLoading = true
        } else {
            isRefreshing = true
        }

        do {
            snapshot = try Self.loadSnapshot(databaseURL: databaseURL)
            lastError = nil
        } catch let error as LoadError {
            lastError = error
        } catch {
            lastError = .queryStepFailed(message: error.localizedDescription)
        }

        hasLoaded = true
        isLoading = false
        isRefreshing = false
    }

    func refreshIfNeeded() {
        guard hasLoaded == false else { return }
        refresh()
    }

    static func loadSnapshot(databaseURL: URL) throws -> OpenCodeUsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw LoadError.databaseNotFound(path: databaseURL.path)
        }

        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw LoadError.databaseOpenFailed(message: message)
        }
        defer { sqlite3_close(db) }

        let sql = """
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
            time_created,
            time_updated
        from session
        order by time_updated desc
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoadError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [OpenCodeSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 13)) / 1000)
            let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 14)) / 1000)

            sessions.append(
                OpenCodeSessionRecord(
                    id: stringColumn(statement, index: 0),
                    title: stringColumn(statement, index: 1),
                    directory: stringColumn(statement, index: 2),
                    agent: stringColumn(statement, index: 3),
                    modelProviderID: stringColumn(statement, index: 4),
                    modelID: stringColumn(statement, index: 5),
                    modelVariant: optionalStringColumn(statement, index: 6),
                    inputTokens: Int(sqlite3_column_int64(statement, 7)),
                    outputTokens: Int(sqlite3_column_int64(statement, 8)),
                    reasoningTokens: Int(sqlite3_column_int64(statement, 9)),
                    cacheReadTokens: Int(sqlite3_column_int64(statement, 10)),
                    cacheWriteTokens: Int(sqlite3_column_int64(statement, 11)),
                    cost: sqlite3_column_double(statement, 12),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        let resultCode = sqlite3_errcode(db)
        guard resultCode == SQLITE_OK || resultCode == SQLITE_DONE else {
            throw LoadError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        return OpenCodeUsageSnapshot(sessions: sessions)
    }
}

private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
}

private func optionalStringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
    let value = stringColumn(statement, index: index)
    return value.isEmpty ? nil : value
}
```

- [ ] **Step 2: Add the store file to the app target**

Update `pulse.xcodeproj/project.pbxproj` so `OpenCodeUsageStore.swift` is in the `Managers` group and app Sources phase.

- [ ] **Step 3: Run the SQLite tests to verify GREEN**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeUsageStoreTests
```

Expected: PASS.

- [ ] **Step 4: Commit the loader implementation**

```bash
git add pulse/Managers/OpenCodeUsageStore.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add OpenCode usage store"
```

### Task 5: Build the searchable selector control and Agent Usage view

**Files:**
- Create: `pulse/Views/SearchableSelectorView.swift`
- Create: `pulse/Views/AgentUsageView.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add a reusable searchable selector view**

Create `pulse/Views/SearchableSelectorView.swift` with:

```swift
import SwiftUI

struct SearchableSelectorOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}

struct SearchableSelectorView: View {
    let label: String
    let placeholder: String
    let selectedTitle: String
    let options: [SearchableSelectorOption]
    let onSelect: (SearchableSelectorOption) -> Void

    @State private var isPresented = false
    @State private var query = ""

    private var filteredOptions: [SearchableSelectorOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Button {
                query = ""
                isPresented = true
            } label: {
                HStack(spacing: 8) {
                    Text(selectedTitle.isEmpty ? placeholder : selectedTitle)
                        .foregroundColor(selectedTitle.isEmpty ? .appTertiaryText : .appPrimaryText)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.appSecondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.appFieldBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.appFieldBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(spacing: 10) {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)

                    List(filteredOptions) { option in
                        Button {
                            onSelect(option)
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .foregroundColor(.appPrimaryText)
                                Text(option.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundColor(.appSecondaryText)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 360, height: 220)
                }
                .padding(12)
            }
        }
    }
}
```

- [ ] **Step 2: Add the Agent Usage view**

Create `pulse/Views/AgentUsageView.swift` with:

```swift
import SwiftUI

struct AgentUsageView: View {
    @EnvironmentObject private var usageStore: OpenCodeUsageStore
    @State private var selectedProjectDirectory: String? = nil
    @State private var selectedSessionID: String? = nil

    private var isSessionScope: Bool {
        selectedProjectDirectory != nil && selectedSessionID != nil
    }

    private var scope: OpenCodeScope {
        if let selectedProjectDirectory, let selectedSessionID {
            return .session(projectDirectory: selectedProjectDirectory, sessionID: selectedSessionID)
        }
        if let selectedProjectDirectory {
            return .project(directory: selectedProjectDirectory)
        }
        return .allProjects
    }

    private var summary: OpenCodeUsageSummary {
        usageStore.snapshot.summary(for: scope)
    }

    private var projectOptions: [OpenCodeProjectOption] {
        usageStore.snapshot.projectOptions
    }

    private var sessionOptions: [OpenCodeSessionOption] {
        guard let selectedProjectDirectory else { return [] }
        return usageStore.snapshot.sessionOptions(for: selectedProjectDirectory)
    }

    private var selectedSession: OpenCodeSessionRecord? {
        guard let selectedSessionID else { return nil }
        return usageStore.snapshot.sessions.first(where: { $0.id == selectedSessionID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if usageStore.isLoading {
                    ProgressView("Loading OpenCode usage…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else if let error = usageStore.lastError {
                    errorState(error)
                } else {
                    summaryBlock
                    selectorsBlock
                    detailBlock

                    if isSessionScope == false {
                        byModelBlock
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            usageStore.refreshIfNeeded()
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Agent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appSecondaryText)

                Text("OpenCode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.appPrimaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.appFieldBackground)
                    .clipShape(Capsule())
            }

            Spacer()

            Button(usageStore.isRefreshing ? "Refreshing…" : "Refresh") {
                usageStore.refresh()
            }
            .buttonStyle(.borderless)
            .disabled(usageStore.isRefreshing)
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricCard(title: "Total", value: compact(summary.totalTokens))
                metricCard(title: "Input", value: compact(summary.inputTokens))
                metricCard(title: "Output", value: compact(summary.outputTokens))
                metricCard(title: "Cache Read", value: compact(summary.cacheReadTokens))
            }

            HStack(spacing: 12) {
                summaryPill(title: "Reasoning", value: compact(summary.reasoningTokens))
                summaryPill(title: "Sessions", value: "\(summary.sessionsCount)")
                summaryPill(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "—")
                if summary.cost > 0 {
                    summaryPill(title: "Cost", value: String(format: "$%.2f", summary.cost))
                }
            }
        }
    }

    private var selectorsBlock: some View {
        VStack(spacing: 12) {
            SearchableSelectorView(
                label: "Project",
                placeholder: "All Projects",
                selectedTitle: selectedProjectDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Projects",
                options: [
                    SearchableSelectorOption(
                        id: "__all__",
                        title: "All Projects",
                        subtitle: "Show all OpenCode sessions"
                    )
                ] + projectOptions.map {
                    SearchableSelectorOption(
                        id: $0.directory,
                        title: $0.shortName,
                        subtitle: "\(compact($0.summary.totalTokens)) total tokens • \($0.summary.sessionsCount) sessions • \($0.directory)"
                    )
                }
            ) { option in
                if option.id == "__all__" {
                    selectedProjectDirectory = nil
                    selectedSessionID = nil
                } else {
                    selectedProjectDirectory = option.id
                    selectedSessionID = nil
                }
            }

            if selectedProjectDirectory != nil {
                SearchableSelectorView(
                    label: "Session",
                    placeholder: "Select Session",
                    selectedTitle: sessionOptions.first(where: { $0.id == selectedSessionID })?.title ?? "",
                    options: sessionOptions.map {
                        SearchableSelectorOption(
                            id: $0.id,
                            title: $0.title,
                            subtitle: "\(compact($0.summary.totalTokens)) total tokens • \($0.modelDisplayName)"
                        )
                    }
                ) { option in
                    selectedSessionID = option.id
                }
            }
        }
    }

    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Group {
                detailRow(title: "Total Tokens", value: compact(summary.totalTokens))
                detailRow(title: "Input Tokens", value: compact(summary.inputTokens))
                detailRow(title: "Output Tokens", value: compact(summary.outputTokens))
                detailRow(title: "Reasoning Tokens", value: compact(summary.reasoningTokens))
                detailRow(title: "Cache Read Tokens", value: compact(summary.cacheReadTokens))
                detailRow(title: "Cache Write Tokens", value: compact(summary.cacheWriteTokens))
            }

            Divider()
                .background(Color.appDivider)

            Text("Context")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            switch scope {
            case .allProjects:
                detailRow(title: "Projects Count", value: "\(projectOptions.count)")
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "—")
            case .project(let directory):
                detailRow(title: "Project Name", value: URL(fileURLWithPath: directory).lastPathComponent)
                detailRow(title: "Full Path", value: directory)
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "—")
            case .session:
                detailRow(title: "Title", value: selectedSession?.title ?? "—")
                detailRow(title: "Full Path", value: selectedSession?.directory ?? "—")
                detailRow(title: "Agent", value: selectedSession?.agent ?? "—")
                detailRow(
                    title: "Provider / Model",
                    value: selectedSession.map {
                        OpenCodeUsageSnapshot.modelDisplayName(
                            providerID: $0.modelProviderID,
                            modelID: $0.modelID,
                            variant: $0.modelVariant
                        )
                    } ?? "—"
                )
                detailRow(title: "Created", value: selectedSession.map { shortDateTime($0.createdAt) } ?? "—")
                detailRow(title: "Last Updated", value: selectedSession.map { shortDateTime($0.updatedAt) } ?? "—")
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var byModelBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            ForEach(usageStore.snapshot.modelBreakdown(for: scope)) { model in
                detailRow(
                    title: OpenCodeUsageSnapshot.modelDisplayName(
                        providerID: model.providerID,
                        modelID: model.modelID,
                        variant: model.variant
                    ),
                    value: compact(model.summary.totalTokens)
                )
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorState(_ error: OpenCodeUsageStore.LoadError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenCode data unavailable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)

            Text("Expected DB: \(usageStore.databaseURL.path)")
                .font(.system(size: 11))
                .foregroundColor(.appTertiaryText)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.appPrimaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appSecondaryText)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.appPrimaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.appSecondaryText)
            Spacer()
            Text(value)
                .foregroundColor(.appPrimaryText)
        }
        .font(.system(size: 12))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 3: Add the new view files to the app target**

Update `pulse.xcodeproj/project.pbxproj` so `SearchableSelectorView.swift` and `AgentUsageView.swift` are in the `Views` group and app Sources phase.

- [ ] **Step 4: Build to verify the new views compile**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: BUILD SUCCEEDED, or failures only from missing environment injection/wiring that Task 6 will resolve next.

- [ ] **Step 5: Commit the Agent view layer**

```bash
git add pulse/Views/SearchableSelectorView.swift pulse/Views/AgentUsageView.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent usage views"
```

### Task 6: Wire the feature into AppDelegate, PopoverView, and SettingsView

**Files:**
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulse/Views/PopoverView.swift`
- Modify: `pulse/Views/SettingsView.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the new app-owned managers to AppDelegate**

Update the property block in `pulse/App/AppDelegate.swift` to include:

```swift
private let monitor = SystemMonitor()
private let themeManager = ThemeManager()
private let agentUsageSettings = AgentUsageSettings()
private let openCodeUsageStore = OpenCodeUsageStore()
```

Add a feature observation helper:

```swift
private func setupFeatureObservation() {
    agentUsageSettings.$isEnabled
        .receive(on: RunLoop.main)
        .sink { [weak self] isEnabled in
            self?.updatePanelWidth(agentEnabled: isEnabled, animated: true)
        }
        .store(in: &cancellables)
}

private func updatePanelWidth(agentEnabled: Bool, animated: Bool) {
    guard let panel else { return }
    let targetWidth: CGFloat = agentEnabled ? 460 : 300
    var frame = panel.frame
    guard abs(frame.width - targetWidth) > 1 else { return }
    frame.origin.x -= (targetWidth - frame.width) / 2
    frame.size.width = targetWidth
    panel.setFrame(frame, display: true, animate: animated)
    panel.minSize = NSSize(width: agentEnabled ? 420 : 280, height: 320)
}
```

Call `setupFeatureObservation()` from `applicationDidFinishLaunching()` right after `setupThemeObservation()`.

- [ ] **Step 2: Inject the new environment objects and widen the created panel when needed**

In `makePanel()`, change the starting content rect:

```swift
contentRect: NSRect(x: 0, y: 0, width: agentUsageSettings.isEnabled ? 460 : 300, height: 420)
```

Update the hosting controller root view:

```swift
let vc = NSHostingController(
    rootView: PopoverView()
        .environmentObject(monitor)
        .environmentObject(themeManager)
        .environmentObject(agentUsageSettings)
        .environmentObject(openCodeUsageStore)
)
```

Also update the zoom reset width in `InputPanel.zoom(_:)`:

```swift
let baseWidth: CGFloat = UserDefaults.standard.object(forKey: AgentUsageSettings.userDefaultsKey) as? Bool == true ? 460 : 300
setFrame(NSRect(x: current.origin.x, y: screen.visibleFrame.maxY - 420, width: baseWidth, height: 420), display: true, animate: true)
```

In `openPanel()`, trigger a refresh when the feature is enabled so opening the menu bar panel reloads OpenCode data:

```swift
if agentUsageSettings.isEnabled {
    openCodeUsageStore.refresh()
}
```

- [ ] **Step 3: Gate the third tab and embed the AgentUsageView**

Replace `pulse/Views/PopoverView.swift` with:

```swift
import SwiftUI

struct PopoverView: View {
    @AppStorage("selectedTab") private var selectedTab = 0
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var agentUsageSettings: AgentUsageSettings

    private var availableTabs: [(title: String, tag: Int)] {
        var tabs: [(String, Int)] = [("Overview", 0), ("Processes", 1)]
        if agentUsageSettings.isEnabled {
            tabs.append(("Agent", 2))
        }
        return tabs
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(availableTabs, id: \.tag) { tab in
                        Text(tab.title).tag(tab.tag)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .background(Color.appDivider)

                ZStack {
                    OverviewView()
                        .opacity(selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 0)

                    ProcessListView()
                        .opacity(selectedTab == 1 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 1)

                    if agentUsageSettings.isEnabled {
                        AgentUsageView()
                            .opacity(selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: agentUsageSettings.isEnabled ? 460 : 300, minHeight: 360)
        .id(themeManager.currentTheme)
        .onChange(of: agentUsageSettings.isEnabled) { isEnabled in
            if isEnabled == false && selectedTab == 2 {
                selectedTab = 0
            }
        }
        .onAppear {
            if agentUsageSettings.isEnabled == false && selectedTab == 2 {
                selectedTab = 0
            }
        }
    }
}
```

- [ ] **Step 4: Add the Agent Usage section to Settings**

Update `pulse/Views/SettingsView.swift`:

```swift
private enum Section: Hashable {
    case theme
    case agentUsage
}
```

Add the sidebar button:

```swift
Button {
    selectedSection = .agentUsage
} label: {
    HStack {
        Image(systemName: "person.2.wave.2")
            .font(.system(size: 12))
        Text("Agent Usage")
            .font(.system(size: 13, weight: .medium))
        Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(selectedSection == .agentUsage ? Color.accentColor.opacity(0.14) : .clear)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
}
.buttonStyle(.plain)
```

Add the environment object:

```swift
@EnvironmentObject var agentUsageSettings: AgentUsageSettings
```

Replace the right pane with a switch:

```swift
Group {
    switch selectedSection {
    case .theme:
        themeContent
    case .agentUsage:
        agentUsageContent
    }
}
```

Add the agent usage section:

```swift
private var agentUsageContent: some View {
    VStack(alignment: .leading, spacing: 14) {
        Text("Agent Usage")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text("Enable an optional OpenCode usage analysis tab in the menu bar panel. Data is loaded on demand from the local OpenCode database.")
            .font(.system(size: 13))
            .foregroundColor(.appSecondaryText)
            .fixedSize(horizontal: false, vertical: true)

        Toggle("Enable Agent Usage", isOn: $agentUsageSettings.isEnabled)
            .toggleStyle(.switch)

        Spacer()
    }
}
```

Finally, inject the new environment object in `makeSettingsWindow()`:

```swift
rootView: SettingsView()
    .environmentObject(themeManager)
    .environmentObject(agentUsageSettings)
```

- [ ] **Step 5: Bump the app version for the new feature**

Update `pulse.xcodeproj/project.pbxproj`:

```text
MARKETING_VERSION = 1.4.0;
```

Replace both existing `1.3.1` entries with `1.4.0`.

- [ ] **Step 6: Run the full build and test suite**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected:

- tests PASS
- build succeeds

- [ ] **Step 7: Commit the app wiring**

```bash
git add pulse/App/AppDelegate.swift pulse/Views/PopoverView.swift pulse/Views/SettingsView.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: wire agent usage into pulse"
```

### Task 7: Manual verification in the running app

**Files:**
- Modify: none

- [ ] **Step 1: Launch the built app**

Run:

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'pulse.app' -path '*/Debug/*' | head -1)"
```

Expected: Pulse launches in the menu bar.

- [ ] **Step 2: Verify the feature toggle flow**

Manual checks:

```text
1. Open Settings and confirm Agent Usage defaults to Off.
2. Turn Agent Usage On and confirm the Agent tab appears in the main panel.
3. Turn Agent Usage Off and confirm the Agent tab disappears.
4. If the Agent tab was selected, confirm the app falls back to Overview instead of showing an invalid tab.
```

- [ ] **Step 3: Verify the Agent tab data flow**

Manual checks:

```text
1. Re-enable Agent Usage and open the Agent tab.
2. Confirm the header shows OpenCode and a Refresh control.
3. Confirm the Project selector defaults to All Projects.
4. Confirm project options are searchable and sorted by total token usage descending.
5. Select a project and confirm the Session selector appears.
6. Confirm session options are searchable and sorted by total token usage descending within that project.
7. Select a session and confirm the detail section updates to the selected session scope.
8. Return to All Projects and confirm the Session selector disappears.
```

- [ ] **Step 4: Verify fallback states**

Manual checks:

```text
1. Temporarily point OpenCodeUsageStore(databaseURL:) to a missing temp file.
2. Rebuild and open the Agent tab.
3. Confirm the view shows a readable error state and the expected DB path.
4. Restore the default database URL before finalizing the branch.
```

- [ ] **Step 5: Commit only if a verification-driven code fix was required**

```bash
git add pulse/App/AppDelegate.swift pulse/Views/PopoverView.swift pulse/Views/SettingsView.swift pulse/Views/AgentUsageView.swift pulse/Views/SearchableSelectorView.swift pulse/Managers/OpenCodeUsageStore.swift pulse/Managers/OpenCodeUsageModels.swift pulse/Managers/AgentUsageSettings.swift pulse.xcodeproj/project.pbxproj
git commit -m "fix: address agent usage verification issues"
```
