import XCTest
@testable import Pulse

final class SessionManagementStoreTests: XCTestCase {
    @MainActor
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

    @MainActor
    func testSelectingSessionLoadsTranscriptLazily() {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")],
            transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        XCTAssertEqual(store.transcriptState, .idle)

        store.selectSession(id: "codex::2")

        XCTAssertEqual(
            store.transcriptState,
            .loaded([TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)])
        )
    }

    @MainActor
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

    @MainActor
    func testSessionManagementStoreRefreshesOnlyOncePerWindowLifecycleSeed() {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        store.refreshIfNeeded()

        XCTAssertEqual(repository.loadManagedSessionsCallCount, 1)
    }

    @MainActor
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

    @MainActor
    func testProjectFilterOptionsFollowActiveSourcePivot() {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        store.selectedSourceFilter = .codex

        XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/b"])
    }

    @MainActor
    func testVisibleSessionsClearsStaleProjectSelectionWhenSourcePivotChanges() {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        store.selectedProjectPath = "/tmp/a"
        store.selectedSourceFilter = .codex

        XCTAssertNil(store.selectedProjectPath)
        XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/b"])
        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::2"])
    }

    @MainActor
    func testSelectionClearsWhenFiltersHideSelectedSession() {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ],
            transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        store.selectSession(id: "codex::2")
        store.selectedSourceFilter = .openCode

        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(store.transcriptState, .idle)
        XCTAssertEqual(store.visibleSessions().map(\.id), ["opencode::1"])
    }

    @MainActor
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

    func testManagedSessionSummaryUsesStableIdentityAcrossAgents() {
        let openCode = ManagedSessionSummary(
            id: "opencode::session-1",
            source: .openCode,
            rawSessionID: "session-1",
            title: "OpenCode Session",
            projectPath: "/tmp/project",
            projectName: "project",
            subtitle: "OpenCode",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let codex = ManagedSessionSummary(
            id: "codex::session-1",
            source: .codex,
            rawSessionID: "session-1",
            title: "Codex Session",
            projectPath: "/tmp/project",
            projectName: "project",
            subtitle: "Codex",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertNotEqual(openCode.id, codex.id)
    }

    func testTranscriptLoadStateLoadingValueIsDistinctFromIdleAndLoaded() {
        XCTAssertNotEqual(TranscriptLoadState.idle, .loading)
        XCTAssertNotEqual(TranscriptLoadState.loading, .loaded([]))
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

    func testLoadManagedSessionsReturnsCodexWhenOpenCodeFails() throws {
        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/missing.sqlite") },
            loadOpenCodeSnapshot: { _ in throw OpenCodeUsageQuery.QueryError.databaseNotFound(path: "/tmp/missing.sqlite") },
            loadCodexSnapshot: {
                CodexUsageSnapshot(sessions: [
                    CodexSessionRecord(
                        id: "thread_1",
                        title: "Codex Session",
                        cwd: "/tmp/project",
                        model: "gpt-5.4",
                        modelProvider: "openai",
                        tokensUsed: 100,
                        inputTokens: nil,
                        outputTokens: nil,
                        reasoningTokens: nil,
                        cacheReadTokens: nil,
                        reasoningEffort: "",
                        threadSource: "user",
                        agentNickname: nil,
                        agentRole: nil,
                        createdAt: Date(timeIntervalSince1970: 1_000),
                        updatedAt: Date(timeIntervalSince1970: 2_000)
                    )
                ])
            }
        )

        let sessions = try repository.loadManagedSessions()

        XCTAssertEqual(sessions.map(\.id), ["codex::thread_1"])
    }

    func testLoadManagedSessionsReturnsOpenCodeWhenCodexFails() throws {
        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/opencode.sqlite") },
            loadOpenCodeSnapshot: { _ in
                OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "ses_1::openai::gpt-5.4::default",
                        title: "OpenCode Session",
                        directory: "/tmp/project",
                        agent: "build",
                        modelProviderID: "openai",
                        modelID: "gpt-5.4",
                        modelVariant: "default",
                        inputTokens: 0,
                        outputTokens: 0,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 0,
                        cost: 0,
                        createdAt: Date(timeIntervalSince1970: 1_000),
                        updatedAt: Date(timeIntervalSince1970: 2_000)
                    )
                ])
            },
            loadCodexSnapshot: { throw CodexUsageQuery.QueryError.databaseNotFound(path: "/tmp/.codex") }
        )

        let sessions = try repository.loadManagedSessions()

        XCTAssertEqual(sessions.map(\.id), ["opencode::ses_1::openai::gpt-5.4::default"])
        XCTAssertEqual(sessions.first?.rawSessionID, "ses_1")
    }

    func testLoadTranscriptUsesDiscoveredOpenCodeDatabaseInstance() throws {
        let expectedDatabaseURL = URL(fileURLWithPath: "/tmp/discovered.sqlite")
        let fallbackDatabaseURL = URL(fileURLWithPath: "/tmp/fallback.sqlite")
        var transcriptDatabasePaths: [String] = []

        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: {
                if transcriptDatabasePaths.isEmpty {
                    return expectedDatabaseURL
                }
                return fallbackDatabaseURL
            },
            loadOpenCodeSnapshot: { databaseURL in
                XCTAssertEqual(databaseURL, expectedDatabaseURL)
                return OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "ses_1::openai::gpt-5.4::default",
                        title: "OpenCode Session",
                        directory: "/tmp/project",
                        agent: "build",
                        modelProviderID: "openai",
                        modelID: "gpt-5.4",
                        modelVariant: "default",
                        inputTokens: 0,
                        outputTokens: 0,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 0,
                        cost: 0,
                        createdAt: Date(timeIntervalSince1970: 1_000),
                        updatedAt: Date(timeIntervalSince1970: 2_000)
                    )
                ])
            },
            loadOpenCodeTranscript: { databaseURL, sessionID in
                transcriptDatabasePaths.append(databaseURL.path)
                XCTAssertEqual(sessionID, "ses_1")
                return [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]
            },
            loadCodexSnapshot: { CodexUsageSnapshot(sessions: []) }
        )

        let sessions = try repository.loadManagedSessions()
        _ = try repository.loadTranscript(for: sessions[0])

        XCTAssertEqual(transcriptDatabasePaths, [expectedDatabaseURL.path])
    }
}

private final class StubSessionManagementRepository: SessionManagementRepositorying {
    var sessions: [ManagedSessionSummary] = []
    var transcripts: [String: [TranscriptTurn]] = [:]
    private(set) var loadManagedSessionsCallCount = 0

    init(
        sessions: [ManagedSessionSummary] = [],
        transcripts: [String: [TranscriptTurn]] = [:]
    ) {
        self.sessions = sessions
        self.transcripts = transcripts
    }

    func loadManagedSessions() throws -> [ManagedSessionSummary] {
        loadManagedSessionsCallCount += 1
        return sessions
    }

    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn] {
        transcripts[session.id] ?? []
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

private func makeManagedSession(
    id: String,
    source: AgentSource,
    title: String,
    projectPath: String
) -> ManagedSessionSummary {
    ManagedSessionSummary(
        id: id,
        source: source,
        rawSessionID: id.components(separatedBy: "::").dropFirst().first ?? id,
        title: title,
        projectPath: projectPath,
        projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
        subtitle: source.rawValue,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
}
