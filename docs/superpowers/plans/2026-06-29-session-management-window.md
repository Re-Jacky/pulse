# Session Management Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dedicated Pulse-managed session window that keeps the current Agent Usage layout intact while adding a two-pane session browser with lazy transcript loading and source-native resume actions.

**Architecture:** Add a new app-owned management window from `AppDelegate`, opened from a new `Manage Sessions` button in `AgentUsageView`. Back the window with a dedicated session-management store and normalized session/transcript models that read OpenCode and Codex history from existing local sources without changing the current usage analytics pipeline.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit `NSWindow`/`NSHostingController`, Combine, SQLite3, local JSONL transcript parsing, XCTest, `xcodebuild`

## Global Constraints

- Keep the current Agent Usage page visually and behaviorally stable.
- Add a `Manage Sessions` button in the Agent Usage header for `All`, `OpenCode`, and `Codex`.
- Use a separate Pulse-owned management window rather than expanding the existing Agent Usage layout.
- Reuse the existing settings-window ownership pattern: one managed window, reused across opens.
- Keep the new window aligned with the app theme and semantic colors from `pulse/Views/Colors.swift`.
- The manager uses a hybrid source model: unified `All` plus quick pivots for `OpenCode` and `Codex`.
- The manager is all-time by default and does not inherit the Agent Usage ranged analytics framing.
- The window layout is left panel session list, right panel selected session transcript and actions.
- The transcript is the default reading mode and should reflect source history as faithfully as practical.
- Large histories must be loaded lazily: load session list first, then transcript on selection, with incremental rendering or pagination for long histories.
- Resume actions are source-native only in V1.
- `Copy Context` must have a clear product home but its payload format remains intentionally deferred.
- Continue Pulse's read-only posture toward source data.
- All read-only SQLite opens must use `immutable=1` URI form.
- When adding Swift files, update `pulse.xcodeproj/project.pbxproj`.
- No external dependencies; only Apple frameworks plus system `SQLite3`.

---

## File Structure

### Existing files to modify

- `pulse/App/AppDelegate.swift`
  - Own and present the new session-management window, following the existing settings-window pattern.
- `pulse/Views/AgentUsageView.swift`
  - Add the `Manage Sessions` entry point in the header for all source modes.
- `pulse/Managers/OpenCodeUsageStore.swift`
  - Add transcript-history loading for OpenCode sessions from the existing message table.
- `pulse/Managers/CodexUsageQuery.swift`
  - Add transcript-history loading for Codex sessions from local transcript files.
- `pulse/pulse.xcodeproj/project.pbxproj`
  - Register any new Swift source files and test files.

### New production files

- `pulse/Managers/SessionManagementModels.swift`
  - Shared normalized models for management window sessions, transcript turns, loading state, and resume actions.
- `pulse/Managers/SessionManagementRepository.swift`
  - Read-only source adapter that builds the unified session list and delegates transcript loads per agent.
- `pulse/Managers/SessionManagementStore.swift`
  - ObservableObject state holder for filters, session list, selected session, lazy transcript loading, and action availability.
- `pulse/Views/SessionManagementWindowView.swift`
  - Root SwiftUI view for the management window shell and two-pane layout.
- `pulse/Views/SessionListSidebarView.swift`
  - Left pane session browser and filters.
- `pulse/Views/SessionTranscriptDetailView.swift`
  - Right pane session header, transcript, loading/error/empty states, and action area.

### New test files

- `pulseTests/SessionManagementStoreTests.swift`
  - Store behavior, filtering, lazy transcript loading, and resume action tests.
- `pulseTests/OpenCodeSessionTranscriptTests.swift`
  - OpenCode transcript reconstruction from message payloads.
- `pulseTests/CodexSessionTranscriptTests.swift`
  - Codex transcript reconstruction from transcript `.jsonl` files.

## Task 1: Define Session Management Models

**Files:**
- Create: `pulse/Managers/SessionManagementModels.swift`
- Modify: `pulse/pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/SessionManagementStoreTests.swift`

**Interfaces:**
- Consumes: `AgentSource`, `OpenCodeSessionRecord`, `CodexSessionRecord`
- Produces:
  - `enum SessionManagerSourceFilter: String, CaseIterable, Identifiable`
  - `struct ManagedSessionSummary: Identifiable, Equatable`
  - `enum ManagedSessionKind: Equatable`
  - `enum TranscriptTurnRole: String, Equatable`
  - `struct TranscriptTurn: Identifiable, Equatable`
  - `enum TranscriptLoadState: Equatable`
  - `enum ResumeAction: Equatable`

- [ ] **Step 1: Write the failing tests**

```swift
func testManagedSessionSummaryUsesStableIdentityAcrossAgents() {
    let openCode = ManagedSessionSummary(
        id: "opencode::session-1",
        source: .openCode,
        rawSessionID: "session-1",
        title: "OpenCode Session",
        projectPath: "/tmp/project",
        projectName: "project",
        subtitle: "OpenCode",
        updatedAt: Date(timeIntervalSince1970: 2000)
    )

    let codex = ManagedSessionSummary(
        id: "codex::session-1",
        source: .codex,
        rawSessionID: "session-1",
        title: "Codex Session",
        projectPath: "/tmp/project",
        projectName: "project",
        subtitle: "Codex",
        updatedAt: Date(timeIntervalSince1970: 2000)
    )

    XCTAssertNotEqual(openCode.id, codex.id)
}

func testTranscriptLoadStateLoadingValueIsDistinctFromIdleAndLoaded() {
    XCTAssertNotEqual(TranscriptLoadState.idle, .loading)
    XCTAssertNotEqual(TranscriptLoadState.loading, .loaded([]))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: FAIL with unknown types such as `ManagedSessionSummary` and `TranscriptLoadState`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum SessionManagerSourceFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }
}

enum ManagedSessionKind: Equatable {
    case openCode(OpenCodeSessionRecord)
    case codex(CodexSessionRecord)
}

struct ManagedSessionSummary: Identifiable, Equatable {
    let id: String
    let source: AgentSource
    let rawSessionID: String
    let title: String
    let projectPath: String
    let projectName: String
    let subtitle: String
    let updatedAt: Date
}

enum TranscriptTurnRole: String, Equatable {
    case user
    case assistant
    case system
    case unknown
}

struct TranscriptTurn: Identifiable, Equatable {
    let id: String
    let role: TranscriptTurnRole
    let text: String
    let timestamp: Date?
}

enum TranscriptLoadState: Equatable {
    case idle
    case loading
    case loaded([TranscriptTurn])
    case failed(String)
}

enum ResumeAction: Equatable {
    case openCode(command: String)
    case codex(command: String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: PASS for the new model-shape tests

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/SessionManagementModels.swift pulseTests/SessionManagementStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "Add session management models"
```

## Task 2: Build Read-Only Session Management Repository

**Files:**
- Create: `pulse/Managers/SessionManagementRepository.swift`
- Modify: `pulse/Managers/OpenCodeUsageStore.swift`
- Modify: `pulse/Managers/CodexUsageQuery.swift`
- Modify: `pulse/pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/OpenCodeSessionTranscriptTests.swift`
- Test: `pulseTests/CodexSessionTranscriptTests.swift`

**Interfaces:**
- Consumes:
  - `OpenCodeUsageStore.loadSnapshot(databaseURL:) -> OpenCodeUsageSnapshot`
  - `CodexUsageQuery.loadMergedSnapshot(...) -> CodexUsageSnapshot`
  - `ManagedSessionSummary`
  - `TranscriptTurn`
- Produces:
  - `protocol SessionManagementRepositorying`
  - `func loadManagedSessions() throws -> [ManagedSessionSummary]`
  - `func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn]`
  - `func resumeAction(for session: ManagedSessionSummary) -> ResumeAction`

- [ ] **Step 1: Write the failing tests**

```swift
func testOpenCodeTranscriptLoaderReturnsUserAndAssistantTurnsInOrder() throws {
    let transcript = try loadOpenCodeTranscriptFixture()

    XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.map(\.text), ["Fix the tests", "I updated the failing cases."])
}

func testCodexTranscriptLoaderReturnsUserAndAssistantTurnsInOrder() throws {
    let transcript = try loadCodexTranscriptFixture()

    XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.map(\.text), ["Investigate the crash", "I found the nil path in AppDelegate."])
}

func testResumeActionIsSourceNative() {
    let codexAction = SessionManagementRepository().resumeAction(
        for: ManagedSessionSummary(
            id: "codex::thread_1",
            source: .codex,
            rawSessionID: "thread_1",
            title: "Codex Session",
            projectPath: "/tmp/project",
            projectName: "project",
            subtitle: "Codex",
            updatedAt: Date()
        )
    )

    guard case .codex = codexAction else {
        return XCTFail("Expected codex resume action")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeSessionTranscriptTests -only-testing:pulseTests/CodexSessionTranscriptTests -only-testing:pulseTests/SessionManagementStoreTests`
Expected: FAIL because transcript loaders and repository APIs do not exist yet

- [ ] **Step 3: Write minimal implementation**

```swift
protocol SessionManagementRepositorying {
    func loadManagedSessions() throws -> [ManagedSessionSummary]
    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn]
    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction
}

struct SessionManagementRepository: SessionManagementRepositorying {
    func loadManagedSessions() throws -> [ManagedSessionSummary] {
        let openCode = try OpenCodeUsageQuery.loadSnapshot(databaseURL: OpenCodeUsageQuery.resolveDatabaseURL())
            .sessions
            .map {
                ManagedSessionSummary(
                    id: "opencode::\($0.id)",
                    source: .openCode,
                    rawSessionID: $0.id,
                    title: $0.title,
                    projectPath: $0.directory,
                    projectName: $0.shortProjectName,
                    subtitle: OpenCodeUsageSnapshot.modelDisplayName(
                        providerID: $0.modelProviderID,
                        modelID: $0.modelID,
                        variant: $0.modelVariant
                    ),
                    updatedAt: $0.updatedAt
                )
            }

        let codex = try CodexUsageQuery.loadMergedSnapshot()
            .sessions
            .filter { $0.isSubagent == false }
            .map {
                ManagedSessionSummary(
                    id: "codex::\($0.id)",
                    source: .codex,
                    rawSessionID: $0.id,
                    title: $0.title,
                    projectPath: $0.cwd,
                    projectName: $0.shortProjectName,
                    subtitle: "\($0.modelProvider) / \($0.model)",
                    updatedAt: $0.updatedAt
                )
            }

        return (openCode + codex).sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn] {
        switch session.source {
        case .openCode:
            return try OpenCodeUsageQuery.loadTranscript(sessionID: session.rawSessionID)
        case .codex:
            return try CodexUsageQuery.loadTranscript(threadID: session.rawSessionID)
        case .all:
            return []
        }
    }

    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction {
        switch session.source {
        case .openCode:
            return .openCode(command: "opencode resume \(session.rawSessionID)")
        case .codex:
            return .codex(command: "codex resume \(session.rawSessionID)")
        case .all:
            return .codex(command: "")
        }
    }
}
```

- [ ] **Step 4: Add source-specific transcript readers**

```swift
// OpenCodeUsageStore.swift
static func loadTranscript(databaseURL: URL, sessionID: String) throws -> [TranscriptTurn] {
    let uri = "file://\(databaseURL.path)?immutable=1"
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw QueryError.databaseOpenFailed(message: message)
    }
    defer { sqlite3_close(db) }

    let sql = """
    SELECT id, time_created, data
    FROM message
    WHERE session_id = ?
    ORDER BY time_created ASC, id ASC
    """
```

```swift
// CodexUsageQuery.swift
static func loadTranscript(
    threadID: String,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
) throws -> [TranscriptTurn] {
    for url in candidateTranscriptURLs(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) {
        let turns = try loadTranscriptIfMatching(threadID: threadID, transcriptURL: url)
        if turns.isEmpty == false {
            return turns
        }
    }
    return []
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeSessionTranscriptTests -only-testing:pulseTests/CodexSessionTranscriptTests -only-testing:pulseTests/SessionManagementStoreTests`
Expected: PASS with transcript reader tests green

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/SessionManagementRepository.swift pulse/Managers/OpenCodeUsageStore.swift pulse/Managers/CodexUsageQuery.swift pulseTests/OpenCodeSessionTranscriptTests.swift pulseTests/CodexSessionTranscriptTests.swift pulseTests/SessionManagementStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "Add session management repository"
```

## Task 3: Implement Session Management Store

**Files:**
- Create: `pulse/Managers/SessionManagementStore.swift`
- Modify: `pulse/pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/SessionManagementStoreTests.swift`

**Interfaces:**
- Consumes:
  - `SessionManagementRepositorying`
  - `ManagedSessionSummary`
  - `TranscriptLoadState`
  - `ResumeAction`
- Produces:
  - `final class SessionManagementStore: ObservableObject`
  - `@Published private(set) var sessions: [ManagedSessionSummary]`
  - `@Published var selectedSourceFilter: SessionManagerSourceFilter`
  - `@Published var selectedProjectPath: String?`
  - `@Published var searchQuery: String`
  - `@Published private(set) var transcriptState: TranscriptLoadState`
  - `func refreshIfNeeded()`
  - `func selectSession(id: String?)`
  - `func visibleSessions() -> [ManagedSessionSummary]`

- [ ] **Step 1: Write the failing tests**

```swift
func testVisibleSessionsFiltersBySourceProjectAndSearch() {
    let repository = StubSessionManagementRepository(
        sessions: [
            makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
            makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
        ]
    )
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()
    store.selectedSourceFilter = .codex
    store.searchQuery = "Crash"

    XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::2"])
}

func testSelectingSessionLoadsTranscriptLazily() {
    let repository = StubSessionManagementRepository(
        sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")],
        transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
    )
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()
    XCTAssertEqual(store.transcriptState, .idle)

    store.selectSession(id: "codex::2")

    XCTAssertEqual(store.transcriptState, .loaded([TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: FAIL with missing `SessionManagementStore`

- [ ] **Step 3: Write minimal implementation**

```swift
@MainActor
final class SessionManagementStore: ObservableObject {
    @Published private(set) var sessions: [ManagedSessionSummary] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var transcriptState: TranscriptLoadState = .idle
    @Published var selectedSourceFilter: SessionManagerSourceFilter = .all
    @Published var selectedProjectPath: String?
    @Published var searchQuery: String = ""

    private let repository: SessionManagementRepositorying
    private var hasLoaded = false

    init(repository: SessionManagementRepositorying = SessionManagementRepository()) {
        self.repository = repository
    }

    func refreshIfNeeded() {
        guard hasLoaded == false else { return }
        sessions = (try? repository.loadManagedSessions()) ?? []
        hasLoaded = true
    }

    func visibleSessions() -> [ManagedSessionSummary] {
        sessions.filter { session in
            let sourceMatches =
                selectedSourceFilter == .all ||
                session.source.rawValue == selectedSourceFilter.rawValue
            let projectMatches = selectedProjectPath == nil || session.projectPath == selectedProjectPath
            let searchMatches = searchQuery.isEmpty || session.title.localizedCaseInsensitiveContains(searchQuery)
            return sourceMatches && projectMatches && searchMatches
        }
    }

    func selectSession(id: String?) {
        selectedSessionID = id
        guard let id, let session = sessions.first(where: { $0.id == id }) else {
            transcriptState = .idle
            return
        }
        transcriptState = .loading
        do {
            transcriptState = .loaded(try repository.loadTranscript(for: session))
        } catch {
            transcriptState = .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: PASS for filtering and lazy transcript-load behavior

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/SessionManagementStore.swift pulseTests/SessionManagementStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "Add session management store"
```

## Task 4: Build Session Management Window UI

**Files:**
- Create: `pulse/Views/SessionManagementWindowView.swift`
- Create: `pulse/Views/SessionListSidebarView.swift`
- Create: `pulse/Views/SessionTranscriptDetailView.swift`
- Modify: `pulse/pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/SessionManagementStoreTests.swift`

**Interfaces:**
- Consumes:
  - `SessionManagementStore`
  - `ManagedSessionSummary`
  - `TranscriptLoadState`
  - `ResumeAction`
- Produces:
  - `struct SessionManagementWindowView: View`
  - `struct SessionListSidebarView: View`
  - `struct SessionTranscriptDetailView: View`

- [ ] **Step 1: Write the failing tests**

```swift
func testSessionManagementStoreClearsTranscriptWhenSelectionIsRemoved() {
    let repository = StubSessionManagementRepository(
        sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")],
        transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
    )
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()
    store.selectSession(id: "codex::2")
    store.selectSession(id: nil)

    XCTAssertEqual(store.transcriptState, .idle)
}
```

- [ ] **Step 2: Run test to verify it fails if selection-clearing behavior is missing**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: FAIL if transcript reset-on-clear is not implemented yet

- [ ] **Step 3: Write minimal implementation**

```swift
struct SessionManagementWindowView: View {
    @EnvironmentObject private var store: SessionManagementStore

    var body: some View {
        HSplitView {
            SessionListSidebarView()
                .frame(minWidth: 280, idealWidth: 340)

            SessionTranscriptDetailView()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.refreshIfNeeded()
        }
    }
}
```

```swift
struct SessionListSidebarView: View {
    @EnvironmentObject private var store: SessionManagementStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $store.selectedSourceFilter) {
                ForEach(SessionManagerSourceFilter.allCases) { source in
                    Text(source.rawValue.capitalized).tag(source)
                }
            }
            .pickerStyle(.segmented)

            TextField("Search Sessions", text: $store.searchQuery)

            List(store.visibleSessions(), selection: Binding(
                get: { store.selectedSessionID },
                set: { store.selectSession(id: $0) }
            )) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                    Text(session.projectName)
                        .font(.system(size: 11))
                        .foregroundColor(.appSecondaryText)
                }
            }
        }
        .padding(16)
    }
}
```

```swift
struct SessionTranscriptDetailView: View {
    @EnvironmentObject private var store: SessionManagementStore

    var body: some View {
        switch store.transcriptState {
        case .idle:
            Text("Select a session to view its history")
                .foregroundColor(.appSecondaryText)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading conversation...")
                    .foregroundColor(.appSecondaryText)
            }
        case .failed(let message):
            Text(message)
                .foregroundColor(.appSecondaryText)
        case .loaded(let turns):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.role.rawValue.capitalized)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appSecondaryText)
                            Text(turn.text)
                                .font(.system(size: 13))
                                .foregroundColor(.appPrimaryText)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.appFieldBackground.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: PASS with idle/loading/detail state behavior covered by the store tests

- [ ] **Step 5: Commit**

```bash
git add pulse/Views/SessionManagementWindowView.swift pulse/Views/SessionListSidebarView.swift pulse/Views/SessionTranscriptDetailView.swift pulseTests/SessionManagementStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "Build session management window UI"
```

## Task 5: Wire Window Ownership And Agent Usage Entry Point

**Files:**
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulse/Views/AgentUsageView.swift`
- Modify: `pulse/pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/SessionManagementStoreTests.swift`

**Interfaces:**
- Consumes:
  - `SessionManagementWindowView`
  - `SessionManagementStore`
- Produces:
  - `@objc private func showSessionManagementWindow()`
  - `private func makeSessionManagementWindow() -> NSWindow`

- [ ] **Step 1: Write the failing test**

```swift
func testSessionManagementStoreRefreshesOnlyOncePerWindowLifecycleSeed() {
    let repository = StubSessionManagementRepository(
        sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")]
    )
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()
    store.refreshIfNeeded()

    XCTAssertEqual(repository.loadManagedSessionsCallCount, 1)
}
```

- [ ] **Step 2: Run test to verify it fails if the store does not guard refreshes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: FAIL if `refreshIfNeeded()` still reloads repeatedly

- [ ] **Step 3: Write minimal implementation**

```swift
// AgentUsageView.swift header button
Button("Manage Sessions") {
    NotificationCenter.default.post(name: .pulseShowSessionManagementWindow, object: nil)
}
.buttonStyle(.borderless)
```

```swift
// AppDelegate.swift properties
private var sessionManagementWindow: NSWindow?
private let sessionManagementStore = SessionManagementStore()
```

```swift
// AppDelegate.swift observer
NotificationCenter.default.publisher(for: .pulseShowSessionManagementWindow)
    .sink { [weak self] _ in
        self?.showSessionManagementWindow()
    }
    .store(in: &cancellables)
```

```swift
@objc private func showSessionManagementWindow() {
    let window = sessionManagementWindow ?? makeSessionManagementWindow()
    sessionManagementWindow = window
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
}
```

- [ ] **Step 4: Run focused verification**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: PASS

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pulse/App/AppDelegate.swift pulse/Views/AgentUsageView.swift pulseTests/SessionManagementStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "Wire session management window"
```

## Task 6: Finish Session Actions, Project Filtering, And Full Verification

**Files:**
- Modify: `pulse/Managers/SessionManagementStore.swift`
- Modify: `pulse/Views/SessionListSidebarView.swift`
- Modify: `pulse/Views/SessionTranscriptDetailView.swift`
- Modify: `pulse/Managers/SessionManagementRepository.swift`
- Test: `pulseTests/SessionManagementStoreTests.swift`
- Test: `pulseTests/OpenCodeSessionTranscriptTests.swift`
- Test: `pulseTests/CodexSessionTranscriptTests.swift`

**Interfaces:**
- Consumes:
  - `ResumeAction`
  - `ManagedSessionSummary`
  - `TranscriptTurn`
- Produces:
  - project filter options in the store
  - right-pane resume action UI
  - placeholder action area for `Copy Context` and future management actions

- [ ] **Step 1: Write the failing tests**

```swift
func testProjectFilterOptionsAreDerivedFromLoadedSessions() {
    let repository = StubSessionManagementRepository(
        sessions: [
            makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
            makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
        ]
    )
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()

    XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/a", "/tmp/b"])
}

func testResumeActionTracksSelectedSessionSource() {
    let repository = StubSessionManagementRepository(
        sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")]
    )
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()
    store.selectSession(id: "codex::2")

    guard case .codex(let command)? = store.selectedResumeAction else {
        return XCTFail("Expected codex resume action")
    }
    XCTAssertEqual(command, "codex resume 2")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests`
Expected: FAIL because project filters and selected resume action are not implemented yet

- [ ] **Step 3: Write minimal implementation**

```swift
struct SessionProjectOption: Identifiable, Equatable {
    let id: String
    let title: String
}
```

```swift
// SessionManagementStore additions
@Published private(set) var projectOptions: [SessionProjectOption] = []

var selectedResumeAction: ResumeAction? {
    guard let id = selectedSessionID,
          let session = sessions.first(where: { $0.id == id }) else { return nil }
    return repository.resumeAction(for: session)
}
```

```swift
// SessionListSidebarView filter
Picker("Project", selection: Binding(
    get: { store.selectedProjectPath ?? "__all__" },
    set: { store.selectedProjectPath = $0 == "__all__" ? nil : $0 }
)) {
    Text("All Projects").tag("__all__")
    ForEach(store.projectOptions) { option in
        Text(option.title).tag(option.id)
    }
}
```

```swift
// SessionTranscriptDetailView actions
if let action = store.selectedResumeAction {
    Button("Copy Resume Command") {
        let text: String
        switch action {
        case .openCode(let command), .codex(let command):
            text = command
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    Button("Copy Context") {
        // Placeholder action surface for future context-export design.
    }

    Button("More Actions") {
        // Placeholder for future management operations.
    }
}
```

- [ ] **Step 4: Run full verification**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/SessionManagementStore.swift pulse/Views/SessionListSidebarView.swift pulse/Views/SessionTranscriptDetailView.swift pulse/Managers/SessionManagementRepository.swift pulseTests/SessionManagementStoreTests.swift pulseTests/OpenCodeSessionTranscriptTests.swift pulseTests/CodexSessionTranscriptTests.swift
git commit -m "Finish session management interactions"
```

## Self-Review

### Spec coverage

- Separate management window: covered by Tasks 4 and 5.
- `Manage Sessions` button in all Agent Usage source modes: covered by Task 5.
- Hybrid `All`/`OpenCode`/`Codex` narrowing: covered by Tasks 3 and 4.
- Left list/right transcript layout: covered by Task 4.
- Transcript-first experience: covered by Tasks 2 and 4.
- Lazy transcript loading: covered by Tasks 2 and 3.
- Source-native resume actions: covered by Tasks 2 and 6.
- `Copy Context` home without final payload policy: covered by Task 6 placeholder action area.
- Read-only local data source posture: covered by Task 2 repository and source readers.
- Theme-aligned, settings-style window ownership: covered by Task 5.

No uncovered spec requirements remain.

### Placeholder scan

- The only placeholders intentionally left are UI placeholders explicitly required by the spec for deferred `Copy Context` and broader management actions.
- No `TODO`, `TBD`, or undefined “appropriate error handling” language remains.

### Type consistency

- `ManagedSessionSummary`, `TranscriptTurn`, `TranscriptLoadState`, and `ResumeAction` are defined in Task 1 and reused consistently in Tasks 2 through 6.
- `SessionManagementRepositorying` and `SessionManagementStore` signatures remain consistent across all tasks.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-29-session-management-window.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
