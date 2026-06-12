# Agent Usage Data Flow Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Agent Usage so panel-open/manual refresh is the only general SQL boundary, Codex session detail is lazily cached, and every Agent screen section renders from one top-level in-memory source of truth.

**Architecture:** Add a thin `AgentUsageRepository` in front of the existing query types, move loaded state and refresh-generation ownership into `AgentUsageStore`, and expose one derived `AgentUsageDerivedViewData` object per selection. Keep SQLite query structs pure and keep SwiftUI views focused on rendering plus persisted selection wiring.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Foundation, SQLite3, XCTest, Xcode project file updates via `add_files.rb`

---

## Planned Files And Responsibilities

- Create: `pulse/Managers/AgentUsageRepository.swift`
  Thin wrapper around `OpenCodeUsageQuery` and `CodexUsageQuery`, plus a small protocol seam for store tests.
- Create: `pulse/Managers/AgentUsageViewData.swift`
  UI-facing derived structs such as `AgentUsageSelection`, `AgentModelGroupBy`, `AgentUsageLoadedState`, `CodexSessionDetailState`, and `AgentUsageDerivedViewData`.
- Create: `pulseTests/AgentUsageStoreTests.swift`
  Store behavior tests for refresh boundaries, reconciliation, and Codex detail cache invalidation.
- Create: `pulseTests/AgentUsageViewDataTests.swift`
  Pure derivation tests for summaries, project/session options, token flow, and source-specific rendering flags.
- Modify: `pulse/Managers/AgentUsageModels.swift`
  Keep shared enums and summaries, add any lightweight shared helpers that truly belong at the common model layer.
- Modify: `pulse/Managers/CodexUsageModels.swift`
  Add raw `CodexSessionDetail`.
- Modify: `pulse/Managers/AgentUsageStore.swift`
  Replace the current mixed store/view flow with repository-backed loaded state, refresh generation, derived data, and detail cache.
- Modify: `pulse/Views/AgentUsageView.swift`
  Replace view-owned calculations and SQL-triggering hooks with store-driven derived rendering.
- Modify: `pulse/Views/CodexSessionDetailView.swift`
  Accept one detail state input instead of reading flat global arrays from the store.
- Modify: `pulse/App/AppDelegate.swift`
  Keep panel-open refresh at the top level, but use the refactored store API.
- Modify: `pulseTests/OpenCodeUsageStoreTests.swift`
  Rename to match `OpenCodeUsageQuery` usage and keep query coverage compiling.
- Modify: `pulse.xcodeproj/project.pbxproj`
  Add new Swift and test files to build phases; bump `MARKETING_VERSION` from `1.7.2` to `1.7.3`.

---

### Task 1: Add The Repository And View-Data Types

**Files:**
- Create: `pulse/Managers/AgentUsageRepository.swift`
- Create: `pulse/Managers/AgentUsageViewData.swift`
- Modify: `pulse/Managers/CodexUsageModels.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/AgentUsageViewDataTests.swift`

- [ ] **Step 1: Write the failing derivation tests**

Create `pulseTests/AgentUsageViewDataTests.swift` with tests that pin the new selection and derivation behavior before adding implementation:

```swift
import XCTest
@testable import Pulse

final class AgentUsageViewDataTests: XCTestCase {
    func testSelectionProducesSessionScopeOnlyWhenProjectAndSessionExist() {
        let selection = AgentUsageSelection(
            source: .openCode,
            timeRange: .last7Days,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: "ses_1",
            modelGroupBy: .model
        )

        XCTAssertEqual(selection.scope, .session(projectDirectory: "/Users/zyao/Desktop/pulse", sessionID: "ses_1"))
        XCTAssertTrue(selection.isSessionScope)
    }

    func testSelectionUsesAllProjectsScopeWhenProjectIsNil() {
        let selection = AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .provider
        )

        XCTAssertEqual(selection.scope, .allProjects)
        XCTAssertFalse(selection.isSessionScope)
    }

    func testLoadedStateStartsWithEmptyCodexDetailCache() {
        let state = AgentUsageLoadedState(
            openCodeSnapshot: OpenCodeUsageSnapshot(sessions: []),
            codexSnapshot: CodexUsageSnapshot(sessions: []),
            refreshGeneration: 0,
            codexDetailCache: [:]
        )

        XCTAssertTrue(state.codexDetailCache.isEmpty)
        XCTAssertEqual(state.refreshGeneration, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageViewDataTests
```

Expected: FAIL with missing `AgentUsageSelection`, `AgentUsageLoadedState`, and `scope` / `isSessionScope` symbols.

- [ ] **Step 3: Add the new view-data and repository types**

Create `pulse/Managers/AgentUsageViewData.swift`:

```swift
import Foundation

enum AgentModelGroupBy: String, Equatable {
    case provider
    case model
}

struct AgentUsageSelection: Equatable {
    let source: AgentSource
    let timeRange: AgentTimeRange
    let projectDirectory: String?
    let sessionID: String?
    let modelGroupBy: AgentModelGroupBy

    var scope: AgentScope {
        if let projectDirectory, let sessionID, source != .all {
            return .session(projectDirectory: projectDirectory, sessionID: sessionID)
        }
        if let projectDirectory {
            return .project(directory: projectDirectory)
        }
        return .allProjects
    }

    var isSessionScope: Bool {
        if case .session = scope { return true }
        return false
    }
}

struct AgentUsageLoadedState: Equatable {
    let openCodeSnapshot: OpenCodeUsageSnapshot
    let codexSnapshot: CodexUsageSnapshot
    let refreshGeneration: Int
    let codexDetailCache: [String: CodexSessionDetailState]

    static let empty = AgentUsageLoadedState(
        openCodeSnapshot: OpenCodeUsageSnapshot(sessions: []),
        codexSnapshot: CodexUsageSnapshot(sessions: []),
        refreshGeneration: 0,
        codexDetailCache: [:]
    )
}

enum CodexSessionDetailState: Equatable {
    case idle
    case loading
    case loaded(CodexSessionDetail)
    case failed(message: String)
}

struct AgentUsageMetricCard: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

struct AgentUsageSummaryPill: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

struct AgentUsageDetailRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

struct AgentUsageDerivedViewData: Equatable {
    let selection: AgentUsageSelection
    let scope: AgentScope
    let summary: AgentUsageSummary
    let projectOptions: [SearchableSelectorOption]
    let sessionOptions: [SearchableSelectorOption]
    let tokenFlowData: [TokenUsageDataPoint]
    let usageMetrics: [AgentUsageMetricCard]
    let summaryPills: [AgentUsageSummaryPill]
    let contextRows: [AgentUsageDetailRow]
    let providerBreakdown: [ProviderBreakdown]
    let modelBreakdownRows: [AgentUsageDetailRow]
    let selectedOpenCodeSession: OpenCodeSessionRecord?
    let selectedCodexSession: CodexSessionRecord?
    let codexDetailThreadID: String?
    let isSessionScope: Bool
    let showsByModel: Bool
    let showsTokenFlow: Bool
}
```

Create `pulse/Managers/AgentUsageRepository.swift`:

```swift
import Foundation

protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }

    func loadOpenCodeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail
}

struct AgentUsageRepository: AgentUsageRepositorying {
    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?

    func loadOpenCodeSnapshot() throws -> OpenCodeUsageSnapshot {
        try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
    }

    func loadCodexSnapshot() throws -> CodexUsageSnapshot {
        guard let codexDatabaseURL else {
            throw CodexUsageQuery.QueryError.databaseNotFound(path: "Codex database not found")
        }
        return try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
    }

    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail {
        guard let codexDatabaseURL else {
            throw CodexUsageQuery.QueryError.databaseNotFound(path: "Codex database not found")
        }

        return CodexSessionDetail(
            threadID: threadID,
            edges: try CodexUsageQuery.loadSubagentEdges(databaseURL: codexDatabaseURL, threadID: threadID),
            goals: try CodexUsageQuery.loadGoals(databaseURL: codexDatabaseURL, threadID: threadID)
        )
    }
}
```

Add `CodexSessionDetail` to `pulse/Managers/CodexUsageModels.swift`:

```swift
struct CodexSessionDetail: Equatable {
    let threadID: String
    let edges: [CodexSubagentEdge]
    let goals: [CodexGoal]
}
```

Add the two new files to the Xcode project:

```bash
ruby add_files.rb pulse/Managers/AgentUsageRepository.swift pulse/Managers/AgentUsageViewData.swift pulseTests/AgentUsageViewDataTests.swift
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageViewDataTests
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageRepository.swift pulse/Managers/AgentUsageViewData.swift pulse/Managers/CodexUsageModels.swift pulseTests/AgentUsageViewDataTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "refactor: add agent usage repository and view data types"
```

---

### Task 2: Refactor AgentUsageStore Around Loaded State And Cache Ownership

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulse/Managers/AgentUsageModels.swift`
- Create: `pulseTests/AgentUsageStoreTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/AgentUsageStoreTests.swift`

- [ ] **Step 1: Write the failing store tests**

Create `pulseTests/AgentUsageStoreTests.swift`:

```swift
import XCTest
@testable import Pulse

final class AgentUsageStoreTests: XCTestCase {
    func testRefreshAllLoadsBothSnapshotsAndClearsPreviousDetailCache() {
        let repository = StubAgentUsageRepository()
        repository.openCodeSnapshot = OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1")])
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1")])
        repository.codexDetail = CodexSessionDetail(threadID: "cx_1", edges: [], goals: [])

        let store = AgentUsageStore(repository: repository)

        store.ensureCodexDetailLoaded(for: "cx_1")
        XCTAssertEqual(repository.codexDetailLoadCount, 1)

        store.refreshAll()

        XCTAssertEqual(repository.openCodeLoadCount, 1)
        XCTAssertEqual(repository.codexLoadCount, 1)
        XCTAssertEqual(store.state.refreshGeneration, 1)
        XCTAssertEqual(store.codexDetail(for: "cx_1"), .idle)
    }

    func testEnsureCodexDetailLoadedUsesCacheWithinSameRefreshGeneration() {
        let repository = StubAgentUsageRepository()
        repository.codexDetail = CodexSessionDetail(threadID: "thread_1", edges: [], goals: [])

        let store = AgentUsageStore(repository: repository)

        store.ensureCodexDetailLoaded(for: "thread_1")
        store.ensureCodexDetailLoaded(for: "thread_1")

        XCTAssertEqual(repository.codexDetailLoadCount, 1)
        XCTAssertEqual(store.codexDetail(for: "thread_1"), .loaded(repository.codexDetail))
    }

    func testReconcileClearsSessionForAllSource() {
        let store = AgentUsageStore(repository: StubAgentUsageRepository())
        let selection = AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: "thread_1",
            modelGroupBy: .model
        )

        let reconciled = store.reconcile(selection)

        XCTAssertEqual(reconciled.projectDirectory, "/Users/zyao/Desktop/pulse")
        XCTAssertNil(reconciled.sessionID)
    }
}

private final class StubAgentUsageRepository: AgentUsageRepositorying {
    var openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/opencode.db")
    var codexDatabaseURL: URL? = URL(fileURLWithPath: "/tmp/codex.db")

    var openCodeSnapshot = OpenCodeUsageSnapshot(sessions: [])
    var codexSnapshot = CodexUsageSnapshot(sessions: [])
    var codexDetail = CodexSessionDetail(threadID: "", edges: [], goals: [])

    var openCodeLoadCount = 0
    var codexLoadCount = 0
    var codexDetailLoadCount = 0

    func loadOpenCodeSnapshot() throws -> OpenCodeUsageSnapshot {
        openCodeLoadCount += 1
        return openCodeSnapshot
    }

    func loadCodexSnapshot() throws -> CodexUsageSnapshot {
        codexLoadCount += 1
        return codexSnapshot
    }

    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail {
        codexDetailLoadCount += 1
        return codexDetail
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageStoreTests
```

Expected: FAIL because `AgentUsageStore(repository:)`, `state`, `codexDetail(for:)`, `ensureCodexDetailLoaded(for:)`, and `reconcile(_:)` do not exist yet.

- [ ] **Step 3: Implement the store-owned state, refresh, and cache**

Refactor `pulse/Managers/AgentUsageStore.swift` to center on injected repository state:

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

    @Published private(set) var state: AgentUsageLoadedState
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: LoadError?

    let repository: AgentUsageRepositorying
    let availableSources: [AgentSource]

    private var hasLoadedGeneralData = false

    init(repository: AgentUsageRepositorying? = nil) {
        let defaultRepository = AgentUsageRepository(
            openCodeDatabaseURL: OpenCodeUsageQuery.resolveDatabaseURL(),
            codexDatabaseURL: CodexUsageQuery.resolveDatabaseURL()
        )

        self.repository = repository ?? defaultRepository
        self.state = .empty
        self.availableSources = AgentUsageStore.makeAvailableSources(
            openCodeDatabaseURL: self.repository.openCodeDatabaseURL,
            codexDatabaseURL: self.repository.codexDatabaseURL
        )
    }

    func refreshIfNeeded() {
        guard hasLoadedGeneralData == false else { return }
        refreshAll()
    }

    func refreshAll() {
        if hasLoadedGeneralData == false { isLoading = true } else { isRefreshing = true }

        let nextGeneration = state.refreshGeneration + 1
        let previousState = state
        state = AgentUsageLoadedState(
            openCodeSnapshot: previousState.openCodeSnapshot,
            codexSnapshot: previousState.codexSnapshot,
            refreshGeneration: previousState.refreshGeneration,
            codexDetailCache: [:]
        )

        do {
            let openCodeSnapshot = try repository.loadOpenCodeSnapshot()
            let codexSnapshot = try repository.loadCodexSnapshot()

            state = AgentUsageLoadedState(
                openCodeSnapshot: openCodeSnapshot,
                codexSnapshot: codexSnapshot,
                refreshGeneration: nextGeneration,
                codexDetailCache: [:]
            )

            lastError = nil
            hasLoadedGeneralData = true
        } catch let error as OpenCodeUsageQuery.QueryError {
            lastError = .openCode(error)
        } catch let error as CodexUsageQuery.QueryError {
            lastError = .codex(error)
        } catch {
            lastError = .openCode(.queryStepFailed(message: error.localizedDescription))
        }

        isLoading = false
        isRefreshing = false
    }

    func codexDetail(for threadID: String) -> CodexSessionDetailState {
        state.codexDetailCache[threadID] ?? .idle
    }

    func ensureCodexDetailLoaded(for threadID: String) {
        guard state.codexDetailCache[threadID] == nil || state.codexDetailCache[threadID] == .idle else { return }

        var nextCache = state.codexDetailCache
        nextCache[threadID] = .loading
        state = AgentUsageLoadedState(
            openCodeSnapshot: state.openCodeSnapshot,
            codexSnapshot: state.codexSnapshot,
            refreshGeneration: state.refreshGeneration,
            codexDetailCache: nextCache
        )

        do {
            let detail = try repository.loadCodexDetail(threadID: threadID)
            nextCache[threadID] = .loaded(detail)
        } catch {
            nextCache[threadID] = .failed(message: error.localizedDescription)
        }

        state = AgentUsageLoadedState(
            openCodeSnapshot: state.openCodeSnapshot,
            codexSnapshot: state.codexSnapshot,
            refreshGeneration: state.refreshGeneration,
            codexDetailCache: nextCache
        )
    }

    func reconcile(_ selection: AgentUsageSelection) -> AgentUsageSelection {
        if selection.source == .all {
            return AgentUsageSelection(
                source: selection.source,
                timeRange: selection.timeRange,
                projectDirectory: selection.projectDirectory,
                sessionID: nil,
                modelGroupBy: selection.modelGroupBy
            )
        }

        guard let projectDirectory = selection.projectDirectory else {
            return AgentUsageSelection(
                source: selection.source,
                timeRange: selection.timeRange,
                projectDirectory: nil,
                sessionID: nil,
                modelGroupBy: selection.modelGroupBy
            )
        }

        return AgentUsageSelection(
            source: selection.source,
            timeRange: selection.timeRange,
            projectDirectory: projectDirectory,
            sessionID: selection.sessionID,
            modelGroupBy: selection.modelGroupBy
        )
    }
}
```

Add the new test file to the Xcode project:

```bash
ruby add_files.rb pulseTests/AgentUsageStoreTests.swift
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageStoreTests
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/Managers/AgentUsageModels.swift pulseTests/AgentUsageStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "refactor: centralize agent usage state and codex detail cache"
```

---

### Task 3: Move Derivation Out Of AgentUsageView And Into AgentUsageStore

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulse/Managers/AgentUsageViewData.swift`
- Modify: `pulse/Views/AgentUsageView.swift`
- Modify: `pulse/Views/CodexSessionDetailView.swift`
- Test: `pulseTests/AgentUsageViewDataTests.swift`

- [ ] **Step 1: Expand the failing derivation tests**

Add these tests to `pulseTests/AgentUsageViewDataTests.swift`:

```swift
func testDerivedDataForAllSourceMergesSummariesAndShowsTokenFlow() {
    let store = AgentUsageStore(repository: StubAgentUsageRepository())
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeSnapshot: OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1", tokens: 120)]),
            codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 80)]),
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .all,
        timeRange: .allTime,
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertEqual(data.summary.totalTokens, 200)
    XCTAssertTrue(data.showsTokenFlow)
    XCTAssertFalse(data.isSessionScope)
    XCTAssertTrue(data.sessionOptions.isEmpty)
}

func testDerivedDataForCodexSessionHidesByModelAndCarriesDetailThreadID() {
    let store = AgentUsageStore(repository: StubAgentUsageRepository())
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeSnapshot: OpenCodeUsageSnapshot(sessions: []),
            codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "thread_1", tokens: 80)]),
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .codex,
        timeRange: .allTime,
        projectDirectory: "/Users/zyao/Desktop/pulse",
        sessionID: "thread_1",
        modelGroupBy: .provider
    ))

    XCTAssertTrue(data.isSessionScope)
    XCTAssertFalse(data.showsByModel)
    XCTAssertEqual(data.codexDetailThreadID, "thread_1")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageViewDataTests
```

Expected: FAIL because `derivedData(for:)` and `replaceStateForTesting(_:)` do not exist yet.

- [ ] **Step 3: Implement the derived-data builder and simplify the views**

Extend `pulse/Managers/AgentUsageStore.swift` with a single derivation entrypoint:

```swift
func derivedData(for inputSelection: AgentUsageSelection) -> AgentUsageDerivedViewData {
    let selection = reconcile(inputSelection)
    let openCodeSnapshot = state.openCodeSnapshot.filtered(to: selection.timeRange)
    let codexSnapshot = state.codexSnapshot.filtered(to: selection.timeRange)
    let scope = selection.scope

    let summary: AgentUsageSummary = {
        switch selection.source {
        case .all:
            return AgentUsageSummary.merge(
                openCodeSnapshot.summary(for: scope),
                codexSnapshot.summary(for: scope)
            )
        case .openCode:
            return openCodeSnapshot.summary(for: scope)
        case .codex:
            return codexSnapshot.summary(for: scope)
        }
    }()

    return AgentUsageDerivedViewData(
        selection: selection,
        scope: scope,
        summary: summary,
        projectOptions: buildProjectOptions(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
        sessionOptions: buildSessionOptions(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
        tokenFlowData: buildTokenFlowData(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
        usageMetrics: buildUsageMetrics(summary: summary),
        summaryPills: buildSummaryPills(summary: summary),
        contextRows: buildContextRows(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
        providerBreakdown: buildProviderBreakdown(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
        modelBreakdownRows: buildModelBreakdownRows(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
        selectedOpenCodeSession: selection.source == .openCode ? openCodeSnapshot.sessions.first(where: { $0.id == selection.sessionID }) : nil,
        selectedCodexSession: selection.source == .codex ? codexSnapshot.sessions.first(where: { $0.id == selection.sessionID }) : nil,
        codexDetailThreadID: selection.source == .codex && selection.isSessionScope ? selection.sessionID : nil,
        isSessionScope: selection.isSessionScope,
        showsByModel: selection.source != .all && selection.isSessionScope == false,
        showsTokenFlow: selection.source == .all && selection.timeRange != .today
    )
}
```

Add a testing-only state injector:

```swift
#if DEBUG
func replaceStateForTesting(_ state: AgentUsageLoadedState) {
    self.state = state
}
#endif
```

Refactor `pulse/Views/AgentUsageView.swift` so the view only builds a selection and renders one derived object:

```swift
private var selection: AgentUsageSelection {
    AgentUsageSelection(
        source: AgentSource(rawValue: selectedSourceRawValue) ?? .all,
        timeRange: AgentTimeRange(rawValue: selectedTimeRangeRawValue) ?? .allTime,
        projectDirectory: selectedProjectDirectory.isEmpty ? nil : selectedProjectDirectory,
        sessionID: selectedSessionID.isEmpty ? nil : selectedSessionID,
        modelGroupBy: AgentModelGroupBy(rawValue: modelGroupBy) ?? .model
    )
}

private var data: AgentUsageDerivedViewData {
    agentStore.derivedData(for: selection)
}

var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            header

            if agentStore.isLoading {
                ProgressView("Loading \(data.selection.source.displayName) usage...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else if let error = agentStore.lastError {
                errorState(error)
            } else {
                timeRangeSelector
                selectorsBlock(data: data)
                detailBlock(data: data)

                if data.showsTokenFlow && data.tokenFlowData.isEmpty == false {
                    AgentUsageFlowChartView(dataPoints: data.tokenFlowData)
                }

                if data.showsByModel {
                    byModelBlock(data: data)
                }

                if let threadID = data.codexDetailThreadID,
                   let session = data.selectedCodexSession {
                    CodexSessionDetailView(
                        session: session,
                        detailState: agentStore.codexDetail(for: threadID)
                    )
                }
            }
        }
        .padding(16)
    }
    .onAppear {
        agentStore.refreshIfNeeded()
        if let threadID = data.codexDetailThreadID {
            agentStore.ensureCodexDetailLoaded(for: threadID)
        }
    }
    .onChange(of: selectedSessionID) { _ in
        if let threadID = data.codexDetailThreadID {
            agentStore.ensureCodexDetailLoaded(for: threadID)
        }
    }
}
```

Refactor `pulse/Views/CodexSessionDetailView.swift`:

```swift
import SwiftUI

struct CodexSessionDetailView: View {
    let session: CodexSessionRecord
    let detailState: CodexSessionDetailState

    var body: some View {
        switch detailState {
        case .idle, .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)
        case .loaded(let detail):
            VStack(alignment: .leading, spacing: 12) {
                if detail.edges.isEmpty == false {
                    subagentsSection(edges: detail.edges)
                }
                if detail.goals.isEmpty == false {
                    goalsSection(goals: detail.goals)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageViewDataTests -only-testing:PulseTests/AgentUsageStoreTests
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/Managers/AgentUsageViewData.swift pulse/Views/AgentUsageView.swift pulse/Views/CodexSessionDetailView.swift pulseTests/AgentUsageViewDataTests.swift
git commit -m "refactor: drive agent usage views from derived store data"
```

---

### Task 4: Remove Obsolete SQL Paths, Align Query Tests, Bump Version, And Verify

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulseTests/OpenCodeUsageStoreTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/OpenCodeUsageStoreTests.swift`

- [ ] **Step 1: Write the failing cleanup test updates**

Rename the OpenCode query test class and calls so they reflect the current type names:

```swift
import XCTest
import SQLite3
@testable import Pulse

final class OpenCodeUsageQueryTests: XCTestCase {
    func testLoadSnapshotReadsSessionRowsAndParsesModelJSON() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeUsageQueryTests.sqlite")
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

        let snapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: databaseURL)
        XCTAssertEqual(snapshot.sessions.count, 1)
    }
}
```

- [ ] **Step 2: Run the affected tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/OpenCodeUsageQueryTests
```

Expected: FAIL until the renamed test target/class and references compile cleanly.

- [ ] **Step 3: Remove the obsolete load paths and finalize the integration**

Delete the extra SQL-related store API from `pulse/Managers/AgentUsageStore.swift`:

```swift
// Remove these entirely:
// @Published private(set) var openCodeDailySnapshot: OpenCodeUsageSnapshot?
// @Published private(set) var codexSubagentEdges: [CodexSubagentEdge] = []
// @Published private(set) var codexGoals: [CodexGoal] = []
// @Published private(set) var isLoadingCodexDetail = false
// @Published var selectedSource: AgentSource = .openCode
// func loadOpenCodeDailySnapshot(range: AgentTimeRange)
// func loadCodexDetail(for threadID: String)
// func clearCodexDetail()
```

Keep `pulse/App/AppDelegate.swift` focused on the top-level refresh boundary:

```swift
private func openPanel() {
    let p: InputPanel
    if let existing = panel {
        p = existing
    } else {
        p = makePanel()
        panel = p
    }

    if agentUsageSettings.isEnabled {
        agentUsageStore.refreshAll()
    }

    // existing frame placement and window logic stays unchanged
}
```

Bump the version in `pulse.xcodeproj/project.pbxproj`:

```diff
-				MARKETING_VERSION = 1.7.2;
+				MARKETING_VERSION = 1.7.3;
```

- [ ] **Step 4: Run the focused tests and the required app build**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentUsageStoreTests -only-testing:PulseTests/AgentUsageViewDataTests -only-testing:PulseTests/OpenCodeUsageQueryTests
```

Expected: PASS

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/App/AppDelegate.swift pulseTests/OpenCodeUsageStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "fix: enforce on-demand agent usage loading boundaries"
```

---

## Spec Coverage Check

- General SQL only on panel open/manual refresh: covered by Task 2 store refresh ownership and Task 4 cleanup.
- Codex detail lazy loaded and generation-scoped: covered by Task 2 tests and cache implementation.
- Single source of truth at the top layer: covered by Task 2 loaded state and Task 3 derived rendering.
- All rendering from derived in-memory data: covered by Task 3.
- Removal of extra OpenCode daily SQL path: covered by Task 4.
- Version bump and build verification: covered by Task 4.

## Placeholder Scan

- No `TODO`, `TBD`, or “similar to previous task” placeholders remain.
- Every code-changing step includes concrete code or deletion targets.
- Every verification step includes an exact command and expected outcome.

## Type Consistency Check

- `AgentUsageSelection`, `AgentModelGroupBy`, `AgentUsageLoadedState`, `CodexSessionDetailState`, and `AgentUsageDerivedViewData` are introduced in Task 1 and used consistently in Tasks 2 through 4.
- `AgentUsageRepositorying` is introduced in Task 1 and used for store injection in Task 2.
- `CodexSessionDetail` is introduced in Task 1 and used consistently in store and view tasks.
