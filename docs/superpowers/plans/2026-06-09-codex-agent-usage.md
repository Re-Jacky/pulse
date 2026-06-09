# Codex Agent Usage Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Codex CLI as a second data source alongside OpenCode in the Agent Usage tab, with source-specific features (subagent tracking, goal/budget tracking, reasoning effort).

**Architecture:** Enum-routed `AgentUsageStore` holds per-source snapshots. The view layer uses an `AgentSource` picker to switch between OpenCode and Codex data. Each source has its own data models, SQL queries, and UI sections. Shared types (`AgentTimeRange`, `AgentScope`, `AgentUsageSummary`) are extracted from the existing OpenCode models.

**Tech Stack:** Swift 5.9+, macOS 14.0+, SQLite3, AppKit + SwiftUI, no external dependencies.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `pulse/Managers/AgentUsageModels.swift` | **Create** | Shared types: `AgentSource`, `AgentTimeRange`, `AgentScope`, `AgentUsageSummary` |
| `pulse/Managers/CodexUsageModels.swift` | **Create** | Codex-specific models: `CodexSessionRecord`, `CodexUsageSnapshot`, options, breakdown, subagent edge, goal |
| `pulse/Managers/CodexUsageQuery.swift` | **Create** | Pure functions for Codex SQLite queries (threads, edges, goals) |
| `pulse/Managers/AgentUsageStore.swift` | **Create** | Enum-routed `AgentUsageStore` combining both sources |
| `pulse/Views/AgentSourcePicker.swift` | **Create** | Source toggle capsule buttons |
| `pulse/Views/CodexSessionDetailView.swift` | **Create** | Subagent + goals sections for Codex session scope |
| `pulse/Managers/OpenCodeUsageModels.swift` | **Modify** | Remove shared types (moved to `AgentUsageModels.swift`), update references |
| `pulse/Managers/OpenCodeUsageStore.swift` | **Modify** | Remove `ObservableObject` conformance, refactor to pure query + snapshot builder; `AgentUsageStore` handles published state |
| `pulse/Views/AgentUsageView.swift` | **Modify** | Add source picker, conditional metric cards, route to Codex-specific sections |
| `pulse/App/AppDelegate.swift` | **Modify** | Replace `openCodeUsageStore` with `agentUsageStore`; update injection |
| `pulse/Views/PopoverView.swift` | **Modify** | Update `@EnvironmentObject` from `OpenCodeUsageStore` to `AgentUsageStore` |

---

### Task 1: Create shared agent usage models

**Files:**
- Create: `pulse/Managers/AgentUsageModels.swift`

- [ ] **Step 1: Create `AgentUsageModels.swift` with shared types**

```swift
import Foundation

enum AgentSource: String, CaseIterable, Identifiable {
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .codex: return "Codex"
        }
    }
}

enum AgentTimeRange: String, CaseIterable, Identifiable {
    case allTime = "all_time"
    case today = "today"
    case last7Days = "last_7_days"
    case last30Days = "last_30_days"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allTime: return "All Time"
        case .today: return "Today"
        case .last7Days: return "7 Days"
        case .last30Days: return "30 Days"
        }
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .allTime: return true
        case .today: return Calendar.current.isDate(date, inSameDayAs: now)
        case .last7Days: return date >= now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .last30Days: return date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }
}

enum AgentScope: Equatable {
    case allProjects
    case project(directory: String)
    case session(projectDirectory: String, sessionID: String)
}

struct AgentUsageSummary: Equatable {
    let totalTokens: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let sessionsCount: Int
    let cost: Double?
    let lastUpdated: Date?
}
```

- [ ] **Step 2: Add the file to the Xcode project**

Run:
```bash
ruby add_files.rb
```

But first update `add_files.rb` to include the new file, then run it. Alternatively, manually add the file reference to `project.pbxproj`. The safest approach: create the file, then run:

```bash
ruby -e '
require "xcodeproj"
project_path = "pulse.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join("pulse", "Managers"), true)
file_ref = group.new_reference("AgentUsageModels.swift")
target.add_file_references([file_ref])
project.save
'
```

- [ ] **Step 3: Build to verify the new file compiles**

Run:
```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED (the new file is standalone, no dependencies on it yet)

- [ ] **Step 4: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add shared agent usage models (AgentSource, AgentTimeRange, AgentScope, AgentUsageSummary)"
```

---

### Task 2: Create Codex data models

**Files:**
- Create: `pulse/Managers/CodexUsageModels.swift`

- [ ] **Step 1: Create `CodexUsageModels.swift`**

```swift
import Foundation

struct CodexSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let modelProvider: String
    let tokensUsed: Int
    let reasoningEffort: String
    let threadSource: String
    let agentNickname: String?
    let agentRole: String?
    let createdAt: Date
    let updatedAt: Date

    var shortProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var isSubagent: Bool {
        threadSource == "subagent"
    }
}

struct CodexProjectOption: Identifiable, Equatable {
    let id: String
    let directory: String
    let shortName: String
    let summary: AgentUsageSummary
}

struct CodexSessionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let modelDisplayName: String
    let reasoningEffort: String
    let summary: AgentUsageSummary
    let updatedAt: Date
}

struct CodexModelBreakdown: Identifiable, Equatable {
    var id: String { "\(modelProvider)/\(model)" }

    let modelProvider: String
    let model: String
    let summary: AgentUsageSummary
}

struct CodexSubagentEdge: Equatable {
    let parentThreadID: String
    let childThreadID: String
    let status: String
}

struct CodexGoal: Identifiable, Equatable {
    let id: String
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int?
    let tokensUsed: Int

    var statusColor: String {
        switch status {
        case "active": return "green"
        case "paused": return "yellow"
        case "budget_limited", "usage_limited": return "red"
        case "complete": return "gray"
        default: return "gray"
        }
    }
}

struct CodexUsageSnapshot: Equatable {
    let sessions: [CodexSessionRecord]

    init(sessions: [CodexSessionRecord]) {
        self.sessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func filtered(to range: AgentTimeRange, now: Date = Date()) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            sessions: sessions.filter { range.contains($0.updatedAt, now: now) }
        )
    }

    var projectOptions: [CodexProjectOption] {
        Dictionary(grouping: sessions, by: \.cwd)
            .map { directory, sessions in
                CodexProjectOption(
                    id: directory,
                    directory: directory,
                    shortName: URL(fileURLWithPath: directory).lastPathComponent,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.shortName.localizedCaseInsensitiveCompare(rhs.shortName) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func sessionOptions(for directory: String) -> [CodexSessionOption] {
        sessions
            .filter { $0.cwd == directory && $0.isSubagent == false }
            .map { session in
                CodexSessionOption(
                    id: session.id,
                    title: session.title,
                    directory: session.cwd,
                    modelDisplayName: "\(session.modelProvider) / \(session.model)",
                    reasoningEffort: session.reasoningEffort,
                    summary: Self.makeSummary(from: [session]),
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

    func summary(for scope: AgentScope) -> AgentUsageSummary {
        switch scope {
        case .allProjects:
            return Self.makeSummary(from: sessions.filter { $0.isSubagent == false })
        case .project(let directory):
            return Self.makeSummary(from: sessions.filter { $0.cwd == directory && $0.isSubagent == false })
        case .session(_, let sessionID):
            return Self.makeSummary(from: sessions.filter { $0.id == sessionID })
        }
    }

    func modelBreakdown(for scope: AgentScope) -> [CodexModelBreakdown] {
        let source: [CodexSessionRecord]

        switch scope {
        case .allProjects:
            source = sessions.filter { $0.isSubagent == false }
        case .project(let directory):
            source = sessions.filter { $0.cwd == directory && $0.isSubagent == false }
        case .session:
            return []
        }

        return Dictionary(grouping: source) { "\($0.modelProvider)/\($0.model)" }
            .compactMap { _, sessions in
                guard let first = sessions.first else { return nil }
                return CodexModelBreakdown(
                    modelProvider: first.modelProvider,
                    model: first.model,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    static func makeSummary(from sessions: [CodexSessionRecord]) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: sessions.reduce(0) { $0 + $1.tokensUsed },
            inputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            sessionsCount: sessions.count,
            cost: nil,
            lastUpdated: sessions.map(\.updatedAt).max()
        )
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project**

```bash
ruby -e '
require "xcodeproj"
project_path = "pulse.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join("pulse", "Managers"), true)
file_ref = group.new_reference("CodexUsageModels.swift")
target.add_file_references([file_ref])
project.save
'
```

- [ ] **Step 3: Build to verify compilation**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add pulse/Managers/CodexUsageModels.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add Codex data models (session record, snapshot, options, breakdown, subagent edge, goal)"
```

---

### Task 3: Create Codex SQLite query functions

**Files:**
- Create: `pulse/Managers/CodexUsageQuery.swift`

- [ ] **Step 1: Create `CodexUsageQuery.swift`**

```swift
import Foundation
import SQLite3

enum CodexUsageQuery {
    enum QueryError: Error, Equatable, LocalizedError {
        case databaseNotFound(path: String)
        case databaseOpenFailed(message: String)
        case queryPrepareFailed(message: String)
        case queryStepFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let path):
                return "Codex database not found at \(path)"
            case .databaseOpenFailed(let message):
                return "Failed to open Codex database: \(message)"
            case .queryPrepareFailed(let message):
                return "Failed to prepare Codex query: \(message)"
            case .queryStepFailed(let message):
                return "Failed to read Codex rows: \(message)"
            }
        }
    }

    static func resolveDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let explicitPath = environment["CODEX_DB_PATH"], explicitPath.isEmpty == false {
            let url = URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let defaultPath = homeDirectoryURL
            .appendingPathComponent(".codex")
            .appendingPathComponent("state_5.sqlite")

        guard FileManager.default.fileExists(atPath: defaultPath.path) else {
            return nil
        }
        return defaultPath
    }

    static func loadSnapshot(databaseURL: URL) throws -> CodexUsageSnapshot {
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
        select
            id,
            coalesce(title, ''),
            coalesce(cwd, ''),
            coalesce(model, ''),
            coalesce(model_provider, ''),
            coalesce(tokens_used, 0),
            coalesce(reasoning_effort, ''),
            coalesce(thread_source, ''),
            nullif(agent_nickname, ''),
            nullif(agent_role, ''),
            coalesce(created_at_ms, 0),
            coalesce(updated_at_ms, 0)
        from threads
        where archived = 0 or archived is null
        order by updated_at_ms desc
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [CodexSessionRecord] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 10)) / 1000)
            let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 11)) / 1000)

            sessions.append(
                CodexSessionRecord(
                    id: stringColumn(statement, index: 0),
                    title: stringColumn(statement, index: 1),
                    cwd: stringColumn(statement, index: 2),
                    model: stringColumn(statement, index: 3),
                    modelProvider: stringColumn(statement, index: 4),
                    tokensUsed: Int(sqlite3_column_int64(statement, 5)),
                    reasoningEffort: stringColumn(statement, index: 6),
                    threadSource: stringColumn(statement, index: 7),
                    agentNickname: optionalStringColumn(statement, index: 8),
                    agentRole: optionalStringColumn(statement, index: 9),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return CodexUsageSnapshot(sessions: sessions)
    }

    static func loadSubagentEdges(databaseURL: URL, threadID: String) throws -> [CodexSubagentEdge] {
        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw QueryError.databaseOpenFailed(message: message)
        }
        defer { sqlite3_close(db) }

        let sql = """
        select parent_thread_id, child_thread_id, coalesce(status, '')
        from thread_spawn_edges
        where parent_thread_id = ? or child_thread_id = ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (threadID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (threadID as NSString).utf8String, -1, nil)

        var edges: [CodexSubagentEdge] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            edges.append(
                CodexSubagentEdge(
                    parentThreadID: stringColumn(statement, index: 0),
                    childThreadID: stringColumn(statement, index: 1),
                    status: stringColumn(statement, index: 2)
                )
            )
        }

        return edges
    }

    static func loadGoals(databaseURL: URL, threadID: String) throws -> [CodexGoal] {
        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw QueryError.databaseOpenFailed(message: message)
        }
        defer { sqlite3_close(db) }

        let sql = """
        select coalesce(goal_id, ''),
               coalesce(objective, ''),
               coalesce(status, ''),
               token_budget,
               coalesce(tokens_used, 0)
        from thread_goals
        where thread_id = ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (threadID as NSString).utf8String, -1, nil)

        var goals: [CodexGoal] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            let budget: Int? = {
                let val = sqlite3_column_int64(statement, 3)
                return val > 0 ? Int(val) : nil
            }()

            goals.append(
                CodexGoal(
                    id: stringColumn(statement, index: 0),
                    threadID: threadID,
                    objective: stringColumn(statement, index: 1),
                    status: stringColumn(statement, index: 2),
                    tokenBudget: budget,
                    tokensUsed: Int(sqlite3_column_int64(statement, 4))
                )
            )
        }

        return goals
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

Note: The `stringColumn` and `optionalStringColumn` free functions at the bottom are file-private duplicates. They match the same signatures in `OpenCodeUsageStore.swift`. When we refactor that file in Task 5, we'll extract them to a shared location.

- [ ] **Step 2: Add the file to the Xcode project**

```bash
ruby -e '
require "xcodeproj"
project_path = "pulse.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join("pulse", "Managers"), true)
file_ref = group.new_reference("CodexUsageQuery.swift")
target.add_file_references([file_ref])
project.save
'
```

- [ ] **Step 3: Build to verify compilation**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add pulse/Managers/CodexUsageQuery.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add Codex SQLite query functions (threads, subagent edges, goals)"
```

---

### Task 4: Refactor OpenCode models to use shared types

**Files:**
- Modify: `pulse/Managers/OpenCodeUsageModels.swift` (lines 3-36: remove `OpenCodeTimeRange` and `OpenCodeScope`; lines 70-80: update `OpenCodeUsageSummary` to use `AgentUsageSummary`)

- [ ] **Step 1: Remove `OpenCodeTimeRange` enum (lines 3-36)**

Delete the entire `OpenCodeTimeRange` enum definition from `OpenCodeUsageModels.swift`. It's now in `AgentUsageModels.swift` as `AgentTimeRange`.

- [ ] **Step 2: Remove `OpenCodeScope` enum (lines 38-42)**

Delete the entire `OpenCodeScope` enum definition. It's now in `AgentUsageModels.swift` as `AgentScope`.

- [ ] **Step 3: Remove `OpenCodeUsageSummary` struct (lines 70-80)**

Delete the entire `OpenCodeUsageSummary` struct. Replace all references with `AgentUsageSummary`. Update `OpenCodeProjectOption`, `OpenCodeSessionOption`, and `OpenCodeModelBreakdown` to use `AgentUsageSummary` instead of `OpenCodeUsageSummary`.

Specifically, in `OpenCodeProjectOption` (line 86): change `let summary: OpenCodeUsageSummary` to `let summary: AgentUsageSummary`.

In `OpenCodeSessionOption` (line 95): change `let summary: OpenCodeUsageSummary` to `let summary: AgentUsageSummary`.

In `OpenCodeModelBreakdown` (line 105): change `let summary: OpenCodeUsageSummary` to `let summary: AgentUsageSummary`.

- [ ] **Step 4: Update `OpenCodeUsageSnapshot.makeSummary` to return `AgentUsageSummary`**

Change the return type and constructor call from `OpenCodeUsageSummary(...)` to `AgentUsageSummary(...)`. The `AgentUsageSummary` init has optional token fields, so pass them as non-optional (they're always present for OpenCode):

```swift
static func makeSummary(from sessions: [OpenCodeSessionRecord]) -> AgentUsageSummary {
    AgentUsageSummary(
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
```

- [ ] **Step 5: Update `OpenCodeUsageSnapshot.filtered(to:now:)` signature**

Change parameter type from `OpenCodeTimeRange` to `AgentTimeRange`:

```swift
func filtered(to range: AgentTimeRange, now: Date = Date()) -> OpenCodeUsageSnapshot {
```

- [ ] **Step 6: Update `OpenCodeUsageSnapshot.summary(for:)` parameter type**

Change from `OpenCodeScope` to `AgentScope`:

```swift
func summary(for scope: AgentScope) -> AgentUsageSummary {
```

- [ ] **Step 7: Update `OpenCodeUsageSnapshot.modelBreakdown(for:)` parameter type**

Change from `OpenCodeScope` to `AgentScope`:

```swift
func modelBreakdown(for scope: AgentScope) -> [OpenCodeModelBreakdown] {
```

- [ ] **Step 8: Build to find remaining references to old type names**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -20
```

Expected: Compilation errors in `OpenCodeUsageStore.swift` and `AgentUsageView.swift` referencing `OpenCodeTimeRange`, `OpenCodeScope`, `OpenCodeUsageSummary`. This is expected — we'll fix those in Tasks 5 and 7.

- [ ] **Step 9: Commit (this is an intermediate state — build will fail until Tasks 5 and 7 are done)**

```bash
git add pulse/Managers/OpenCodeUsageModels.swift
git commit -m "refactor: extract shared types from OpenCodeUsageModels to AgentUsageModels"
```

---

### Task 5: Refactor OpenCodeUsageStore — extract query logic, remove ObservableObject

**Files:**
- Modify: `pulse/Managers/OpenCodeUsageStore.swift`

The goal: strip `OpenCodeUsageStore` of its `ObservableObject` conformance and published state. The store becomes a namespace for pure query functions (like `CodexUsageQuery`). The `AgentUsageStore` (Task 6) will hold the published state.

- [ ] **Step 1: Replace `OpenCodeUsageStore` with `OpenCodeUsageQuery` namespace**

Replace the entire file content with:

```swift
import Foundation
import SQLite3

enum OpenCodeUsageQuery {
    enum QueryError: Error, Equatable, LocalizedError {
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

    static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
    }

    static func candidateDatabaseURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = environment["OPENCODE_DB_PATH"], explicitPath.isEmpty == false {
            candidates.append(URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath))
        }

        if let xdgDataHome = environment["XDG_DATA_HOME"], xdgDataHome.isEmpty == false {
            candidates.append(
                URL(fileURLWithPath: NSString(string: xdgDataHome).expandingTildeInPath)
                    .appendingPathComponent("opencode")
                    .appendingPathComponent("opencode.db")
            )
        }

        candidates.append(
            homeDirectoryURL
                .appendingPathComponent(".local")
                .appendingPathComponent("share")
                .appendingPathComponent("opencode")
                .appendingPathComponent("opencode.db")
        )

        if let applicationSupportDirectory {
            candidates.append(
                applicationSupportDirectory
                    .appendingPathComponent("opencode")
                    .appendingPathComponent("opencode.db")
            )
        }

        var seenPaths = Set<String>()
        return candidates.filter { seenPaths.insert($0.path).inserted }
    }

    static func resolveDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL {
        let candidates = candidateDatabaseURLs(
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            applicationSupportDirectory: applicationSupportDirectory
        )

        let existingCandidates = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        guard existingCandidates.isEmpty == false else {
            return candidates.first ?? defaultDatabaseURL
        }

        return existingCandidates.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        } ?? existingCandidates[0]
    }

    static func loadSnapshot(databaseURL: URL) throws -> OpenCodeUsageSnapshot {
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
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [OpenCodeSessionRecord] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

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

- [ ] **Step 2: Commit**

```bash
git add pulse/Managers/OpenCodeUsageStore.swift
git commit -m "refactor: convert OpenCodeUsageStore to OpenCodeUsageQuery namespace (pure functions)"
```

---

### Task 6: Create AgentUsageStore (enum-routed, ObservableObject)

**Files:**
- Create: `pulse/Managers/AgentUsageStore.swift`

- [ ] **Step 1: Create `AgentUsageStore.swift`**

```swift
import Foundation
import Combine

final class AgentUsageStore: ObservableObject {
    enum LoadError: Error, Equatable, LocalizedError {
        case openCode(OpenCodeUsageQuery.QueryError)
        case codex(CodexUsageQuery.QueryError)

        var errorDescription: String? {
            switch self {
            case .openCode(let error): return error.errorDescription
            case .codex(let error): return error.errorDescription
            }
        }
    }

    @Published var selectedSource: AgentSource = .openCode
    @Published private(set) var openCodeSnapshot = OpenCodeUsageSnapshot(sessions: [])
    @Published private(set) var codexSnapshot = CodexUsageSnapshot(sessions: [])
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: LoadError?
    @Published private(set) var codexSubagentEdges: [CodexSubagentEdge] = []
    @Published private(set) var codexGoals: [CodexGoal] = []
    @Published private(set) var isLoadingCodexDetail = false

    private(set) var openCodeHasLoaded = false
    private(set) var codexHasLoaded = false

    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?
    let availableSources: [AgentSource]

    init() {
        let openCodeURL = OpenCodeUsageQuery.resolveDatabaseURL()
        self.openCodeDatabaseURL = openCodeURL

        let codexURL = CodexUsageQuery.resolveDatabaseURL()
        self.codexDatabaseURL = codexURL

        var sources: [AgentSource] = []
        if FileManager.default.fileExists(atPath: openCodeURL.path) {
            sources.append(.openCode)
        }
        if let codexURL, FileManager.default.fileExists(atPath: codexURL.path) {
            sources.append(.codex)
        }
        self.availableSources = sources.isEmpty ? [.openCode, .codex] : sources

        if availableSources.contains(.codex) && !availableSources.contains(.openCode) {
            selectedSource = .codex
        }
    }

    func refresh() {
        switch selectedSource {
        case .openCode:
            let firstLoad = openCodeHasLoaded == false
            if firstLoad { isLoading = true } else { isRefreshing = true }

            do {
                openCodeSnapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
                lastError = nil
            } catch let error as OpenCodeUsageQuery.QueryError {
                lastError = .openCode(error)
            } catch {
                lastError = .openCode(.queryStepFailed(message: error.localizedDescription))
            }

            openCodeHasLoaded = true
            isLoading = false
            isRefreshing = false

        case .codex:
            guard let codexDatabaseURL else {
                lastError = .codex(.databaseNotFound(path: "Codex database not found"))
                return
            }
            let firstLoad = codexHasLoaded == false
            if firstLoad { isLoading = true } else { isRefreshing = true }

            do {
                codexSnapshot = try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
                lastError = nil
            } catch let error as CodexUsageQuery.QueryError {
                lastError = .codex(error)
            } catch {
                lastError = .codex(.queryStepFailed(message: error.localizedDescription))
            }

            codexHasLoaded = true
            isLoading = false
            isRefreshing = false
        }
    }

    func refreshIfNeeded() {
        switch selectedSource {
        case .openCode where !openCodeHasLoaded: refresh()
        case .codex where !codexHasLoaded: refresh()
        default: break
        }
    }

    func refreshAll() {
        if FileManager.default.fileExists(atPath: openCodeDatabaseURL.path) {
            let firstLoad = openCodeHasLoaded == false
            if firstLoad && selectedSource == .openCode { isLoading = true }
            else if selectedSource == .openCode { isRefreshing = true }

            do {
                openCodeSnapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
                if selectedSource == .openCode { lastError = nil }
            } catch let error as OpenCodeUsageQuery.QueryError {
                if selectedSource == .openCode { lastError = .openCode(error) }
            } catch {
                if selectedSource == .openCode { lastError = .openCode(.queryStepFailed(message: error.localizedDescription)) }
            }
            openCodeHasLoaded = true
        }

        if let codexDatabaseURL, FileManager.default.fileExists(atPath: codexDatabaseURL.path) {
            let firstLoad = codexHasLoaded == false
            if firstLoad && selectedSource == .codex { isLoading = true }
            else if selectedSource == .codex { isRefreshing = true }

            do {
                codexSnapshot = try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
                if selectedSource == .codex { lastError = nil }
            } catch let error as CodexUsageQuery.QueryError {
                if selectedSource == .codex { lastError = .codex(error) }
            } catch {
                if selectedSource == .codex { lastError = .codex(.queryStepFailed(message: error.localizedDescription)) }
            }
            codexHasLoaded = true
        }

        isLoading = false
        isRefreshing = false
    }

    func loadCodexDetail(for threadID: String) {
        guard let codexDatabaseURL else { return }
        isLoadingCodexDetail = true

        do {
            codexSubagentEdges = try CodexUsageQuery.loadSubagentEdges(databaseURL: codexDatabaseURL, threadID: threadID)
            codexGoals = try CodexUsageQuery.loadGoals(databaseURL: codexDatabaseURL, threadID: threadID)
        } catch {
            codexSubagentEdges = []
            codexGoals = []
        }

        isLoadingCodexDetail = false
    }

    func clearCodexDetail() {
        codexSubagentEdges = []
        codexGoals = []
    }

    var databasePath: String {
        switch selectedSource {
        case .openCode: return openCodeDatabaseURL.path
        case .codex: return codexDatabaseURL?.path ?? "Codex database not found"
        }
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project**

```bash
ruby -e '
require "xcodeproj"
project_path = "pulse.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join("pulse", "Managers"), true)
file_ref = group.new_reference("AgentUsageStore.swift")
target.add_file_references([file_ref])
project.save
'
```

- [ ] **Step 3: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add AgentUsageStore (enum-routed, ObservableObject) combining OpenCode and Codex"
```

---

### Task 7: Update AppDelegate and PopoverView to use AgentUsageStore

**Files:**
- Modify: `pulse/App/AppDelegate.swift` (line 65: replace `openCodeUsageStore`, line 138: update refresh call, line 240: update injection)
- Modify: `pulse/Views/PopoverView.swift` (no direct reference to `OpenCodeUsageStore`, but verify)

- [ ] **Step 1: In `AppDelegate.swift`, replace `openCodeUsageStore` with `agentUsageStore`**

At line 65, change:
```swift
private let openCodeUsageStore = OpenCodeUsageStore()
```
to:
```swift
private let agentUsageStore = AgentUsageStore()
```

- [ ] **Step 2: Update the refresh call in `openPanel()`**

At line 137-139, change:
```swift
if agentUsageSettings.isEnabled {
    openCodeUsageStore.refresh()
}
```
to:
```swift
if agentUsageSettings.isEnabled {
    agentUsageStore.refreshAll()
}
```

- [ ] **Step 3: Update environment object injection in `makePanel()`**

At line 240, change:
```swift
.environmentObject(openCodeUsageStore)
```
to:
```swift
.environmentObject(agentUsageStore)
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -20
```

Expected: Compilation errors only in `AgentUsageView.swift` (which still references `OpenCodeUsageStore`). We'll fix that in Task 8.

- [ ] **Step 5: Commit**

```bash
git add pulse/App/AppDelegate.swift
git commit -m "refactor: replace OpenCodeUsageStore with AgentUsageStore in AppDelegate"
```

---

### Task 8: Rewrite AgentUsageView to support both sources

**Files:**
- Modify: `pulse/Views/AgentUsageView.swift`

This is the largest change. The view needs to:
1. Accept `AgentUsageStore` instead of `OpenCodeUsageStore`
2. Show a source picker when multiple sources are available
3. Route data derivation through the appropriate snapshot based on `selectedSource`
4. Show conditional metric cards (OpenCode shows all; Codex shows only Total)
5. Show Codex-specific sections (subagents, goals) for session scope

- [ ] **Step 1: Replace the `@EnvironmentObject` and update stored properties**

Replace lines 3-8:
```swift
struct AgentUsageView: View {
    @EnvironmentObject private var usageStore: OpenCodeUsageStore

    @AppStorage("agentUsageSelectedProjectDirectory") private var selectedProjectDirectory = ""
    @AppStorage("agentUsageSelectedSessionID") private var selectedSessionID = ""
    @AppStorage("agentUsageSelectedTimeRange") private var selectedTimeRangeRawValue = OpenCodeTimeRange.allTime.rawValue
```

with:
```swift
struct AgentUsageView: View {
    @EnvironmentObject private var agentStore: AgentUsageStore

    @AppStorage("agentUsageSelectedSource") private var selectedSourceRawValue = AgentSource.openCode.rawValue
    @AppStorage("agentUsageSelectedProjectDirectory") private var selectedProjectDirectory = ""
    @AppStorage("agentUsageSelectedSessionID") private var selectedSessionID = ""
    @AppStorage("agentUsageSelectedTimeRange") private var selectedTimeRangeRawValue = AgentTimeRange.allTime.rawValue
```

- [ ] **Step 2: Add source-aware computed properties**

Add after the stored properties:
```swift
private var selectedSource: AgentSource {
    AgentSource(rawValue: selectedSourceRawValue) ?? .openCode
}

private var selectedTimeRange: AgentTimeRange {
    AgentTimeRange(rawValue: selectedTimeRangeRawValue) ?? .allTime
}

private var scope: AgentScope {
    if let selectedProjectDirectoryValue, let selectedSessionIDValue {
        return .session(projectDirectory: selectedProjectDirectory, sessionID: selectedSessionID)
    }
    if let selectedProjectDirectoryValue {
        return .project(directory: selectedProjectDirectory)
    }
    return .allProjects
}

private var selectedProjectDirectoryValue: String? {
    selectedProjectDirectory.isEmpty ? nil : selectedProjectDirectory
}

private var selectedSessionIDValue: String? {
    selectedSessionID.isEmpty ? nil : selectedSessionID
}
```

- [ ] **Step 3: Add source-routed data derivation**

Replace the existing `summary`, `projectOptions`, `sessionOptions`, `selectedSession`, `filteredSnapshot` computed properties with source-routed versions:

```swift
private var openCodeFilteredSnapshot: OpenCodeUsageSnapshot {
    agentStore.openCodeSnapshot.filtered(to: selectedTimeRange)
}

private var codexFilteredSnapshot: CodexUsageSnapshot {
    agentStore.codexSnapshot.filtered(to: selectedTimeRange)
}

private var summary: AgentUsageSummary {
    switch selectedSource {
    case .openCode: return openCodeFilteredSnapshot.summary(for: scope)
    case .codex: return codexFilteredSnapshot.summary(for: scope)
    }
}

private var projectOptions: [SearchableSelectorOption] {
    switch selectedSource {
    case .openCode:
        return openCodeFilteredSnapshot.projectOptions.map {
            SearchableSelectorOption(
                id: $0.directory,
                title: $0.shortName,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
            )
        }
    case .codex:
        return codexFilteredSnapshot.projectOptions.map {
            SearchableSelectorOption(
                id: $0.directory,
                title: $0.shortName,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
            )
        }
    }
}

private var sessionOptions: [SearchableSelectorOption] {
    switch selectedSource {
    case .openCode:
        guard let selectedProjectDirectoryValue else { return [] }
        return openCodeFilteredSnapshot.sessionOptions(for: selectedProjectDirectory).map {
            SearchableSelectorOption(
                id: $0.id,
                title: $0.title,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime($0.updatedAt)) \u{2022} \($0.modelDisplayName)"
            )
        }
    case .codex:
        guard let selectedProjectDirectoryValue else { return [] }
        return codexFilteredSnapshot.sessionOptions(for: selectedProjectDirectory).map {
            let effort = $0.reasoningEffort.isEmpty ? "" : " \u{2022} \($0.reasoningEffort)"
            return SearchableSelectorOption(
                id: $0.id,
                title: $0.title,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime($0.updatedAt)) \u{2022} \($0.modelDisplayName)\(effort)"
            )
        }
    }
}

private var selectedOpenCodeSession: OpenCodeSessionRecord? {
    guard selectedSource == .openCode, let selectedSessionIDValue else { return nil }
    return openCodeFilteredSnapshot.sessions.first(where: { $0.id == selectedSessionIDValue })
}

private var selectedCodexSession: CodexSessionRecord? {
    guard selectedSource == .codex, let selectedSessionIDValue else { return nil }
    return codexFilteredSnapshot.sessions.first(where: { $0.id == selectedSessionIDValue })
}
```

- [ ] **Step 4: Rewrite the `body` to include source picker and conditional routing**

Replace the `body` property:
```swift
var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            header

            if agentStore.isLoading {
                ProgressView("Loading \(selectedSource.displayName) usage...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else if let error = agentStore.lastError {
                errorState(error)
            } else {
                timeRangeSelector
                selectorsBlock
                detailBlock

                if isSessionScope == false {
                    byModelBlock
                }

                if selectedSource == .codex && isSessionScope {
                    CodexSessionDetailView()
                }
            }
        }
        .padding(16)
    }
    .onAppear {
        agentStore.selectedSource = selectedSource
        agentStore.refreshIfNeeded()
    }
    .onChange(of: agentStore.openCodeSnapshot) { _ in
        if selectedSource == .openCode { reconcileSelection() }
    }
    .onChange(of: agentStore.codexSnapshot) { _ in
        if selectedSource == .codex { reconcileSelection() }
    }
    .onChange(of: selectedTimeRangeRawValue) { _ in
        reconcileSelection()
    }
    .onChange(of: selectedSourceRawValue) { newValue in
        if let source = AgentSource(rawValue: newValue) {
            agentStore.selectedSource = source
            agentStore.refreshIfNeeded()
        }
        reconcileSelection()
    }
    .onChange(of: selectedSessionID) { newID in
        if selectedSource == .codex, let newID, newID.isEmpty == false {
            agentStore.loadCodexDetail(for: newID)
        } else {
            agentStore.clearCodexDetail()
        }
    }
}
```

- [ ] **Step 5: Rewrite `header` to include source picker**

Replace the `header` computed property:
```swift
private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            HStack(spacing: 8) {
                Text("Agent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appSecondaryText)

                if agentStore.availableSources.count > 1 {
                    AgentSourcePicker(
                        availableSources: agentStore.availableSources,
                        selectedSource: selectedSource
                    ) { source in
                        selectedSourceRawValue = source.rawValue
                    }
                } else {
                    Text(selectedSource.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.appPrimaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appFieldBackground)
                        .clipShape(Capsule())
                }
            }

            Spacer()

            Button(agentStore.isRefreshing ? "Refreshing..." : "Refresh") {
                agentStore.refresh()
            }
            .buttonStyle(.borderless)
            .disabled(agentStore.isRefreshing)
        }

        Text("Pulse reads this agent\u{2019}s local usage data from \(agentStore.databasePath) when you refresh the panel.")
            .font(.system(size: 11))
            .foregroundColor(.appSecondaryText)
            .textSelection(.enabled)
    }
}
```

- [ ] **Step 6: Rewrite `selectorsBlock` to use generic `SearchableSelectorOption`**

```swift
private var selectorsBlock: some View {
    VStack(spacing: 12) {
        SearchableSelectorView(
            label: "Project",
            placeholder: "All Projects",
            selectedTitle: selectedProjectDirectoryValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Projects",
            options: [SearchableSelectorOption(id: "__all__", title: "All Projects", subtitle: "Show all \(selectedSource.displayName) sessions")] + projectOptions
        ) { option in
            if option.id == "__all__" {
                selectedProjectDirectory = ""
                selectedSessionID = ""
            } else {
                selectedProjectDirectory = option.id
                selectedSessionID = ""
            }
        }

        if selectedProjectDirectoryValue != nil {
            SearchableSelectorView(
                label: "Session",
                placeholder: "All Sessions",
                selectedTitle: sessionOptions.first(where: { $0.id == selectedSessionIDValue })?.title ?? "All Sessions",
                options: [SearchableSelectorOption(id: "__all__", title: "All Sessions", subtitle: "Show the full project summary")] + sessionOptions
            ) { option in
                selectedSessionID = option.id == "__all__" ? "" : option.id
            }
        }
    }
}
```

- [ ] **Step 7: Rewrite `detailBlock` with conditional metric cards and source-aware context**

```swift
private var detailBlock: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("Usage")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricCard(title: "Total", value: compact(summary.totalTokens))

            if let input = summary.inputTokens {
                metricCard(title: "Input", value: compact(input))
            }
            if let output = summary.outputTokens {
                metricCard(title: "Output", value: compact(output))
            }
            if let cacheRead = summary.cacheReadTokens {
                metricCard(title: "Cache Read", value: compact(cacheRead))
            }
        }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let reasoning = summary.reasoningTokens {
                    summaryPill(title: "Reasoning", value: compact(reasoning))
                }
                if let cacheWrite = summary.cacheWriteTokens {
                    summaryPill(title: "Cache Write", value: compact(cacheWrite))
                }
                summaryPill(title: "Sessions", value: "\(summary.sessionsCount)")
                summaryPill(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
                if let cost = summary.cost, cost > 0 {
                    summaryPill(title: "Cost", value: String(format: "$%.2f", cost))
                }
            }
        }

        Divider()
            .background(Color.appDivider)

        Text("Context")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        switch selectedSource {
        case .openCode:
            openCodeContextRows
        case .codex:
            codexContextRows
        }
    }
    .padding(12)
    .background(Color.appFieldBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private var openCodeContextRows: some View {
    Group {
        switch scope {
        case .allProjects:
            detailRow(title: "Projects Count", value: "\(openCodeFilteredSnapshot.projectOptions.count)")
            detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
            detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
        case .project(let directory):
            detailRow(title: "Project Name", value: URL(fileURLWithPath: directory).lastPathComponent)
            detailRow(title: "Full Path", value: directory)
            detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
            detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
        case .session:
            detailRow(title: "Title", value: selectedOpenCodeSession?.title ?? "-")
            detailRow(title: "Full Path", value: selectedOpenCodeSession?.directory ?? "-")
            detailRow(title: "Agent", value: selectedOpenCodeSession?.agent ?? "-")
            detailRow(
                title: "Provider / Model",
                value: selectedOpenCodeSession.map {
                    OpenCodeUsageSnapshot.modelDisplayName(
                        providerID: $0.modelProviderID,
                        modelID: $0.modelID,
                        variant: $0.modelVariant
                    )
                } ?? "-"
            )
            detailRow(title: "Created", value: selectedOpenCodeSession.map { shortDateTime($0.createdAt) } ?? "-")
            detailRow(title: "Last Updated", value: selectedOpenCodeSession.map { shortDateTime($0.updatedAt) } ?? "-")
        }
    }
}

private var codexContextRows: some View {
    Group {
        switch scope {
        case .allProjects:
            detailRow(title: "Projects Count", value: "\(codexFilteredSnapshot.projectOptions.count)")
            detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
            detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
        case .project(let directory):
            detailRow(title: "Project Name", value: URL(fileURLWithPath: directory).lastPathComponent)
            detailRow(title: "Full Path", value: directory)
            detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
            detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
        case .session:
            detailRow(title: "Title", value: selectedCodexSession?.title ?? "-")
            detailRow(title: "Full Path", value: selectedCodexSession?.cwd ?? "-")
            detailRow(title: "Model", value: selectedCodexSession.map { "\($0.modelProvider) / \($0.model)" } ?? "-")
            if let session = selectedCodexSession, session.reasoningEffort.isEmpty == false {
                detailRow(title: "Reasoning Effort", value: session.reasoningEffort)
            }
            detailRow(title: "Created", value: selectedCodexSession.map { shortDateTime($0.createdAt) } ?? "-")
            detailRow(title: "Last Updated", value: selectedCodexSession.map { shortDateTime($0.updatedAt) } ?? "-")
        }
    }
}
```

- [ ] **Step 8: Update `byModelBlock` for both sources**

```swift
private var byModelBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
        Text("By Model")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        switch selectedSource {
        case .openCode:
            let breakdown = openCodeFilteredSnapshot.modelBreakdown(for: scope)
            if breakdown.isEmpty {
                Text("No model usage data for this scope.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else {
                ForEach(breakdown) { model in
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
        case .codex:
            let breakdown = codexFilteredSnapshot.modelBreakdown(for: scope)
            if breakdown.isEmpty {
                Text("No model usage data for this scope.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else {
                ForEach(breakdown) { model in
                    detailRow(
                        title: "\(model.modelProvider) / \(model.model)",
                        value: compact(model.summary.totalTokens)
                    )
                }
            }
        }
    }
    .padding(12)
    .background(Color.appFieldBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}
```

- [ ] **Step 9: Update `errorState` to use `AgentUsageStore.LoadError`**

```swift
private func errorState(_ error: AgentUsageStore.LoadError) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text("\(selectedSource.displayName) data unavailable")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text(error.localizedDescription)
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)

        Text("Expected DB: \(agentStore.databasePath)")
            .font(.system(size: 11))
            .foregroundColor(.appTertiaryText)
            .textSelection(.enabled)

        Button("Refresh") {
            agentStore.refresh()
        }
        .buttonStyle(.borderless)
    }
    .padding(12)
    .background(Color.appFieldBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}
```

- [ ] **Step 10: Update `reconcileSelection` for both sources**

```swift
private func reconcileSelection() {
    let currentProjectOptions: [String]
    switch selectedSource {
    case .openCode:
        currentProjectOptions = openCodeFilteredSnapshot.projectOptions.map(\.directory)
    case .codex:
        currentProjectOptions = codexFilteredSnapshot.projectOptions.map(\.directory)
    }

    if let selectedProjectDirectoryValue,
       currentProjectOptions.contains(selectedProjectDirectory) == false {
        selectedProjectDirectory = ""
        selectedSessionID = ""
        return
    }

    if let selectedProjectDirectoryValue, let selectedSessionIDValue {
        let validSessionIDs = Set(sessionOptions.map(\.id))
        if validSessionIDs.contains(selectedSessionID) == false {
            selectedProjectDirectory = selectedProjectDirectoryValue
            selectedSessionID = ""
        }
    }
}
```

- [ ] **Step 11: Build and verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED (minus the not-yet-created `AgentSourcePicker` and `CodexSessionDetailView` — we'll create those next)

- [ ] **Step 12: Commit**

```bash
git add pulse/Views/AgentUsageView.swift
git commit -m "feat: rewrite AgentUsageView with source picker, conditional metrics, and Codex context"
```

---

### Task 9: Create AgentSourcePicker view

**Files:**
- Create: `pulse/Views/AgentSourcePicker.swift`

- [ ] **Step 1: Create `AgentSourcePicker.swift`**

```swift
import SwiftUI

struct AgentSourcePicker: View {
    let availableSources: [AgentSource]
    let selectedSource: AgentSource
    let onSelect: (AgentSource) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(availableSources) { source in
                Button {
                    onSelect(source)
                } label: {
                    Text(source.displayName)
                        .font(.system(size: 12, weight: source == selectedSource ? .semibold : .medium))
                        .foregroundColor(source == selectedSource ? .appPrimaryText : .appSecondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(source == selectedSource ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.appFieldBorder, lineWidth: 1)
        )
    }
}
```

- [ ] **Step 2: Add to Xcode project**

```bash
ruby -e '
require "xcodeproj"
project_path = "pulse.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join("pulse", "Views"), true)
file_ref = group.new_reference("AgentSourcePicker.swift")
target.add_file_references([file_ref])
project.save
'
```

- [ ] **Step 3: Commit**

```bash
git add pulse/Views/AgentSourcePicker.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add AgentSourcePicker capsule toggle view"
```

---

### Task 10: Create CodexSessionDetailView (subagents + goals)

**Files:**
- Create: `pulse/Views/CodexSessionDetailView.swift`

- [ ] **Step 1: Create `CodexSessionDetailView.swift`**

```swift
import SwiftUI

struct CodexSessionDetailView: View {
    @EnvironmentObject private var agentStore: AgentUsageStore

    private var edges: [CodexSubagentEdge] { agentStore.codexSubagentEdges }
    private var goals: [CodexGoal] { agentStore.codexGoals }

    private var childThreadIDs: [String] {
        edges.filter { $0.parentThreadID == agentStore.codexSnapshot.sessions.first(where: { _ in true })?.id }
            .map(\.childThreadID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if agentStore.isLoadingCodexDetail {
                ProgressView()
                    .scaleEffect(0.6)
            }

            if edges.isEmpty == false {
                subagentsSection
            }

            if goals.isEmpty == false {
                goalsSection
            }
        }
    }

    private var subagentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subagents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            ForEach(edges, id: \.childThreadID) { edge in
                if let child = agentStore.codexSnapshot.sessions.first(where: { $0.id == edge.childThreadID }) {
                    HStack(spacing: 8) {
                        Text(child.agentNickname ?? "Subagent")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)

                        if let role = child.agentRole, role.isEmpty == false {
                            Text("(\(role))")
                                .font(.system(size: 12))
                                .foregroundColor(.appSecondaryText)
                        }

                        Spacer()

                        Text("\(child.modelProvider) / \(child.model)")
                            .font(.system(size: 11))
                            .foregroundColor(.appSecondaryText)

                        Text(compact(child.tokensUsed))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)
                    }
                } else {
                    HStack {
                        Text("Subagent \(edge.childThreadID.prefix(8))")
                            .font(.system(size: 12))
                            .foregroundColor(.appSecondaryText)

                        Spacer()

                        Text(edge.status)
                            .font(.system(size: 11))
                            .foregroundColor(.appTertiaryText)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goals")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            ForEach(goals) { goal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(goal.objective)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)
                            .lineLimit(2)

                        Spacer()

                        goalStatusBadge(goal.status)
                    }

                    if let budget = goal.tokenBudget, budget > 0 {
                        goalProgressView(used: goal.tokensUsed, budget: budget)
                    } else {
                        Text("\(compact(goal.tokensUsed)) tokens used")
                            .font(.system(size: 11))
                            .foregroundColor(.appSecondaryText)
                    }
                }
                .padding(10)
                .background(Color.appFieldBackground.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func goalStatusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(goalStatusColor(status))
            .clipShape(Capsule())
    }

    private func goalStatusColor(_ status: String) -> Color {
        switch status {
        case "active": return .green
        case "paused": return .yellow
        case "budget_limited", "usage_limited": return .red
        case "complete": return .gray
        default: return .gray
        }
    }

    private func goalProgressView(used: Int, budget: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.appTrackBackground)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(
                            width: min(CGFloat(used) / CGFloat(budget), 1.0) * geometry.size.width,
                            height: 6
                        )
                }
            }
            .frame(height: 6)

            Text("\(compact(used)) / \(compact(budget)) tokens")
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
```

- [ ] **Step 2: Add to Xcode project**

```bash
ruby -e '
require "xcodeproj"
project_path = "pulse.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join("pulse", "Views"), true)
file_ref = group.new_reference("CodexSessionDetailView.swift")
target.add_file_references([file_ref])
project.save
'
```

- [ ] **Step 3: Commit**

```bash
git add pulse/Views/CodexSessionDetailView.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add CodexSessionDetailView with subagent tracking and goal/budget progress"
```

---

### Task 11: Build, fix, and verify

**Files:**
- May need to modify any file that has compilation errors

- [ ] **Step 1: Full build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED. If there are errors, fix them one by one.

- [ ] **Step 2: Check for remaining references to old type names**

```bash
rg 'OpenCodeUsageStore|OpenCodeTimeRange|OpenCodeScope' pulse/ --type swift
```

Expected: No matches in any Swift file (all should be replaced with `AgentUsageStore`, `AgentTimeRange`, `AgentScope`).

- [ ] **Step 3: Verify the app launches**

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'pulse.app' -path '*/Debug/*' | head -1)"
```

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: resolve compilation errors from Codex agent usage integration"
```

---

### Task 12: Bump version

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj` (`MARKETING_VERSION`)

- [ ] **Step 1: Check current version**

```bash
grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj
```

- [ ] **Step 2: Bump minor version (this is a feature)**

```bash
sed -i '' 's/MARKETING_VERSION = .*/MARKETING_VERSION = <new_version>;/' pulse.xcodeproj/project.pbxproj
```

Replace `<new_version>` with the current minor + 1 (e.g., if current is `1.2.0`, bump to `1.3.0`).

- [ ] **Step 3: Commit**

```bash
git add pulse.xcodeproj/project.pbxproj
git commit -m "chore: bump version for Codex agent usage support"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** Each section of the design spec maps to a task. Shared models = Task 1, Codex models = Task 2, Codex queries = Task 3, OpenCode refactor = Tasks 4-5, AgentUsageStore = Task 6, AppDelegate integration = Task 7, AgentUsageView rewrite = Task 8, source picker = Task 9, Codex detail view = Task 10, build verification = Task 11, version bump = Task 12.
- [x] **Placeholder scan:** No TBDs, TODOs, or "implement later" patterns. All code is complete.
- [x] **Type consistency:** `AgentUsageSummary` is used consistently across both Codex and OpenCode paths. `AgentTimeRange` and `AgentScope` replace the old OpenCode-prefixed types everywhere. `AgentSource` enum raw values match the `@AppStorage` key pattern.
- [x] **No external dependencies:** All code uses only Foundation, SQLite3, SwiftUI, AppKit.
