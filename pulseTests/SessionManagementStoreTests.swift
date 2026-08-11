import XCTest
@testable import Pulse

final class SessionManagementStoreTests: XCTestCase {
    @MainActor
    override func tearDown() {
        super.tearDown()
        StubSessionManagementRepository.resetHooks()
    }

    @MainActor
    func testVisibleSessionsFiltersBySourceProjectAndSearch() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.setSelectedSourceFilter(.codex)
        store.setSearchQuery("Crash")

        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::2"])
    }

    @MainActor
    func testVisibleSessionsSearchMatchesManagedAndRawSessionIDs() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "codex::thread_strategy_gateway", source: .codex, title: "Audit", projectPath: "/tmp/a"),
                makeManagedSession(id: "opencode::ses_strategy_gateway::openai::gpt-5.4::default", source: .openCode, title: "Build", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        store.setSearchQuery("thread_strategy")
        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::thread_strategy_gateway"])

        store.setSearchQuery("ses_strategy_gateway")
        XCTAssertEqual(store.visibleSessions().map(\.id), ["opencode::ses_strategy_gateway::openai::gpt-5.4::default"])
    }

    @MainActor
    func testVisibleSessionsPreserveRepositoryOrder() async {
        let newer = makeManagedSession(
            id: "codex::2",
            source: .codex,
            title: "Newer",
            projectPath: "/tmp/a",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let older = makeManagedSession(
            id: "codex::1",
            source: .codex,
            title: "Older",
            projectPath: "/tmp/a",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let repository = StubSessionManagementRepository(
            sessions: [newer, older]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::2", "codex::1"])
    }

    @MainActor
    func testRefreshPublishesPartialSessionListBeforeCompletion() async {
        let partialSessions = [
            makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a")
        ]
        let finalSessions = partialSessions + [
            makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
        ]
        let repository = StubSessionManagementRepository(
            sessions: finalSessions,
            partialManagedSessions: [partialSessions]
        )
        let store = SessionManagementStore(repository: repository)

        let partialPublished = expectation(description: "partial sessions published")
        let allowRefreshToFinish = expectation(description: "allow refresh to finish")
        repository.onPartialManagedSessions = { update in
            if update.sessions.map(\.id) == ["opencode::1"] {
                partialPublished.fulfill()
                XCTWaiter().wait(for: [allowRefreshToFinish], timeout: 1.0)
            }
        }

        store.refreshIfNeeded()
        await fulfillment(of: [partialPublished], timeout: 1.0)

        XCTAssertEqual(store.sessionListState, .loading)
        XCTAssertEqual(store.sessions.map(\.id), ["opencode::1"])
        XCTAssertEqual(store.loadingSources, [.codex, .claudeCode])

        allowRefreshToFinish.fulfill()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertEqual(store.sessionListState, .loaded)
        XCTAssertEqual(store.sessions.map(\.id), ["opencode::1", "codex::2"])
        XCTAssertEqual(store.loadingSources, [])
    }

    @MainActor
    func testSelectingSessionLoadsTranscriptLazily() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")],
            transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        XCTAssertEqual(store.transcriptState, .idle)

        store.selectSession(id: "codex::2")
        XCTAssertEqual(store.transcriptState, .loading([]))
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        XCTAssertEqual(
            store.transcriptState,
            .loaded([TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)])
        )
    }

    @MainActor
    func testSelectingSessionPublishesPartialTranscriptBeforeCompleting() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")],
            transcripts: [
                "codex::2": [
                    TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil),
                    TranscriptTurn(id: "t2", role: .assistant, text: "Done", timestamp: nil)
                ]
            ],
            partialTranscriptBatches: [
                "codex::2": [
                    [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]
                ]
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        let partialPublished = expectation(description: "partial transcript published")
        let allowTranscriptToFinish = expectation(description: "allow transcript to finish")
        repository.onPartialTranscript = { turns in
            if turns.map(\.id) == ["t1"] {
                partialPublished.fulfill()
                XCTWaiter().wait(for: [allowTranscriptToFinish], timeout: 1.0)
            }
        }

        store.selectSession(id: "codex::2")
        await fulfillment(of: [partialPublished], timeout: 1.0)

        XCTAssertEqual(
            store.transcriptState,
            .loading([TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)])
        )

        allowTranscriptToFinish.fulfill()
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        XCTAssertEqual(
            store.transcriptState,
            .loaded([
                TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil),
                TranscriptTurn(id: "t2", role: .assistant, text: "Done", timestamp: nil)
            ])
        )
    }

    @MainActor
    func testSessionManagementStoreClearsTranscriptWhenSelectionIsRemoved() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")],
            transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "codex::2")
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)
        store.selectSession(id: nil)

        XCTAssertEqual(store.transcriptState, .idle)
    }

    @MainActor
    func testSessionManagementStoreRefreshIfNeededReloadsOnEveryCall() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        repository.resetLoadManagedSessionsExpectation()
        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertEqual(repository.loadManagedSessionsCallCount, 2)
    }

    @MainActor
    func testProjectFilterOptionsAreDerivedFromLoadedSessions() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/a", "/tmp/b"])
    }

    @MainActor
    func testProjectFilterOptionsFollowActiveSourcePivot() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.setSelectedSourceFilter(.codex)

        XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/b"])
    }

    @MainActor
    func testProjectFilterOptionsDeduplicateProjectsWithinCurrentSource() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/shared"),
                makeManagedSession(id: "codex::3", source: .codex, title: "Build audit", projectPath: "/tmp/shared"),
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Fix audit", projectPath: "/tmp/other")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.setSelectedSourceFilter(.codex)

        XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/shared"])
    }

    @MainActor
    func testVisibleSessionsClearsStaleProjectSelectionWhenSourcePivotChanges() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.setSelectedProjectPath("/tmp/a")
        store.setSelectedSourceFilter(.codex)

        XCTAssertNil(store.selectedProjectPath)
        XCTAssertEqual(store.projectOptions.map(\.id), ["/tmp/b"])
        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::2"])
    }

    @MainActor
    func testProjectSelectionFiltersVisibleSessions() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b"),
                makeManagedSession(id: "codex::3", source: .codex, title: "Build audit", projectPath: "/tmp/c")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.setSelectedProjectPath("/tmp/c")

        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::3"])
    }

    @MainActor
    func testSetSelectedProjectPathNormalizesUnknownProjectToNil() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        store.setSelectedProjectPath("/tmp/missing")

        XCTAssertNil(store.selectedProjectPath)
    }

    @MainActor
    func testSelectionClearsWhenFiltersHideSelectedSession() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a"),
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
            ],
            transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "codex::2")
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)
        store.setSelectedSourceFilter(.openCode)

        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(store.transcriptState, .idle)
        XCTAssertEqual(store.visibleSessions().map(\.id), ["opencode::1"])
    }

    @MainActor
    func testResumeActionTracksSelectedSessionSource() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "codex::2")

        guard case .codex(let command)? = store.selectedResumeAction else {
            return XCTFail("Expected codex resume action")
        }
        XCTAssertEqual(command, "codex resume 2")
    }

    @MainActor
    func testSelectedSessionSourceTracksOpenCodeSelection() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a")]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "opencode::1")

        XCTAssertEqual(store.selectedSessionSource, .openCode)
    }

    @MainActor
    func testRefreshFailureLeavesRetryableErrorState() async {
        let repository = StubSessionManagementRepository(
            loadManagedSessionsError: NSError(domain: "SessionTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Load failed"])
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertEqual(store.sessionListState, .failed("Load failed"))
        XCTAssertEqual(store.sessions, [])
        XCTAssertEqual(repository.loadManagedSessionsCallCount, 1)

        repository.loadManagedSessionsError = nil
        repository.sessions = [makeManagedSession(id: "codex::3", source: .codex, title: "Recovered", projectPath: "/tmp/c")]
        repository.resetLoadManagedSessionsExpectation()

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertEqual(store.sessionListState, .loaded)
        XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::3"])
        XCTAssertEqual(repository.loadManagedSessionsCallCount, 2)
    }

    @MainActor
    func testRefreshClearsSelectedSessionBeforeReloadingSessions() async {
        let initialSession = makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
        let refreshedSession = makeManagedSession(id: "codex::3", source: .codex, title: "New audit", projectPath: "/tmp/c")
        let repository = StubSessionManagementRepository(
            sessions: [initialSession],
            transcripts: ["codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "codex::2")
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        repository.sessions = [refreshedSession]
        repository.resetLoadManagedSessionsExpectation()

        store.refresh()

        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(store.transcriptState, .idle)

        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        XCTAssertEqual(store.sessions.map(\.id), ["codex::3"])
    }

    @MainActor
    func testSourceScopedLoadingStateTracksPartialSourceCompletion() async {
        let partialSessions = [
            makeManagedSession(id: "opencode::1", source: .openCode, title: "Build fix", projectPath: "/tmp/a")
        ]
        let repository = StubSessionManagementRepository(
            sessions: partialSessions,
            partialManagedSessionUpdates: [
                ManagedSessionsPartialUpdate(
                    sessions: partialSessions,
                    loadedSources: [.openCode]
                )
            ]
        )
        let store = SessionManagementStore(repository: repository)

        let partialPublished = expectation(description: "partial sessions published")
        let allowRefreshToFinish = expectation(description: "allow refresh to finish")
        repository.onPartialManagedSessions = { _ in
            partialPublished.fulfill()
            XCTWaiter().wait(for: [allowRefreshToFinish], timeout: 1.0)
        }

        store.refreshIfNeeded()
        await fulfillment(of: [partialPublished], timeout: 1.0)

        XCTAssertTrue(store.isLoadingSessions(for: .all))
        XCTAssertFalse(store.isLoadingSessions(for: .openCode))
        XCTAssertTrue(store.isLoadingSessions(for: .codex))

        allowRefreshToFinish.fulfill()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        XCTAssertFalse(store.isLoadingSessions(for: .all))
        XCTAssertFalse(store.isLoadingSessions(for: .openCode))
        XCTAssertFalse(store.isLoadingSessions(for: .codex))
    }

    @MainActor
    func testStaleTranscriptLoadDoesNotOverrideNewerSelection() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b"),
                makeManagedSession(id: "codex::3", source: .codex, title: "Build audit", projectPath: "/tmp/c")
            ],
            transcripts: [
                "codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Older", timestamp: nil)],
                "codex::3": [TranscriptTurn(id: "t2", role: .assistant, text: "Newer", timestamp: nil)]
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        let firstTranscriptStarted = expectation(description: "first transcript started")
        let allowFirstTranscriptToFinish = expectation(description: "allow first transcript to finish")
        StubSessionManagementRepository.onLoadTranscript = { sessionID in
            if sessionID == "codex::2" {
                firstTranscriptStarted.fulfill()
                XCTWaiter().wait(for: [allowFirstTranscriptToFinish], timeout: 1.0)
            }
        }

        store.selectSession(id: "codex::2")
        await fulfillment(of: [firstTranscriptStarted], timeout: 1.0)

        repository.resetLoadTranscriptExpectation(expectedFulfillmentCount: 2)
        store.selectSession(id: "codex::3")
        allowFirstTranscriptToFinish.fulfill()
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        XCTAssertEqual(store.selectedSessionID, "codex::3")
        XCTAssertEqual(
            store.transcriptState,
            .loaded([TranscriptTurn(id: "t2", role: .assistant, text: "Newer", timestamp: nil)])
        )
    }

    @MainActor
    func testStalePartialTranscriptDoesNotOverrideNewerSelection() async {
        let repository = StubSessionManagementRepository(
            sessions: [
                makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b"),
                makeManagedSession(id: "codex::3", source: .codex, title: "Build audit", projectPath: "/tmp/c")
            ],
            transcripts: [
                "codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Older", timestamp: nil)],
                "codex::3": [TranscriptTurn(id: "t2", role: .assistant, text: "Newer", timestamp: nil)]
            ],
            partialTranscriptBatches: [
                "codex::2": [[TranscriptTurn(id: "t1", role: .user, text: "Older", timestamp: nil)]]
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

        let firstTranscriptStarted = expectation(description: "first transcript started")
        let allowFirstTranscriptToFinish = expectation(description: "allow first transcript to finish")
        StubSessionManagementRepository.onLoadTranscript = { sessionID in
            if sessionID == "codex::2" {
                firstTranscriptStarted.fulfill()
                XCTWaiter().wait(for: [allowFirstTranscriptToFinish], timeout: 1.0)
            }
        }

        store.selectSession(id: "codex::2")
        await fulfillment(of: [firstTranscriptStarted], timeout: 1.0)

        repository.resetLoadTranscriptExpectation(expectedFulfillmentCount: 2)
        store.selectSession(id: "codex::3")
        allowFirstTranscriptToFinish.fulfill()
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        XCTAssertEqual(store.selectedSessionID, "codex::3")
        XCTAssertEqual(
            store.transcriptState,
            .loaded([TranscriptTurn(id: "t2", role: .assistant, text: "Newer", timestamp: nil)])
        )
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
            updatedAt: Date(timeIntervalSince1970: 2_000),
            transcriptURL: nil
        )

        let codex = ManagedSessionSummary(
            id: "codex::session-1",
            source: .codex,
            rawSessionID: "session-1",
            title: "Codex Session",
            projectPath: "/tmp/project",
            projectName: "project",
            subtitle: "Codex",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            transcriptURL: nil
        )

        XCTAssertNotEqual(openCode.id, codex.id)
    }

    func testTranscriptLoadStateLoadingValueIsDistinctFromIdleAndLoaded() {
        XCTAssertNotEqual(TranscriptLoadState.idle, .loading([]))
        XCTAssertNotEqual(TranscriptLoadState.loading([]), .loaded([]))
    }

    func testTranscriptAutoScrollFollowsNewLastTurn() {
        let previous = [TranscriptTurn(id: "t1", role: .user, text: "Hello", timestamp: nil)]
        let next = previous + [TranscriptTurn(id: "t2", role: .assistant, text: "Hi", timestamp: nil)]

        XCTAssertTrue(
            SessionTranscriptAutoScroll.shouldScrollToBottom(
                from: .loaded(previous),
                to: .loaded(next)
            )
        )
    }

    func testTranscriptAutoScrollIgnoresEquivalentSnapshots() {
        let turns = [TranscriptTurn(id: "t1", role: .user, text: "Hello", timestamp: nil)]

        XCTAssertFalse(
            SessionTranscriptAutoScroll.shouldScrollToBottom(
                from: .loaded(turns),
                to: .loaded(turns)
            )
        )
    }

    func testTranscriptAutoScrollFollowsNewSelectionLoad() {
        let turns = [TranscriptTurn(id: "t1", role: .user, text: "Hello", timestamp: nil)]

        XCTAssertTrue(
            SessionTranscriptAutoScroll.shouldScrollToBottom(
                from: .idle,
                to: .loading(turns)
            )
        )
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
                updatedAt: Date(),
                transcriptURL: nil
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

        let sessions = try repository.loadManagedSessions(enabledSources: Set(AgentSource.selectableCases))

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

        let sessions = try repository.loadManagedSessions(enabledSources: Set(AgentSource.selectableCases))

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

        let sessions = try repository.loadManagedSessions(enabledSources: Set(AgentSource.selectableCases))
        _ = try repository.loadTranscript(for: sessions[0])

        XCTAssertEqual(transcriptDatabasePaths, [expectedDatabaseURL.path])
    }

    func testLoadTranscriptPublishesPartialOpenCodeTurnsThroughRepository() throws {
        let expectedDatabaseURL = URL(fileURLWithPath: "/tmp/discovered.sqlite")
        let partialTurns = [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]
        let finalTurns = partialTurns + [TranscriptTurn(id: "t2", role: .assistant, text: "Done", timestamp: nil)]

        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { expectedDatabaseURL },
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
            loadOpenCodeTranscript: { _, _ in
                finalTurns
            },
            loadOpenCodeTranscriptProgressively: { _, sessionID, onPartialUpdate in
                XCTAssertEqual(sessionID, "ses_1")
                onPartialUpdate(partialTurns)
                return finalTurns
            },
            loadCodexSnapshot: { CodexUsageSnapshot(sessions: []) },
            loadCodexTranscript: { _, _ in [] },
            loadCodexTranscriptProgressively: { _, _, _ in [] }
        )

        let sessions = try repository.loadManagedSessions(enabledSources: Set(AgentSource.selectableCases))
        var publishedBatches: [[TranscriptTurn]] = []
        let transcript = try repository.loadTranscript(for: sessions[0]) { turns in
            publishedBatches.append(turns)
        }

        XCTAssertEqual(publishedBatches, [partialTurns])
        XCTAssertEqual(transcript, finalTurns)
    }

    @MainActor
    func testRefreshSelectedSessionTranscriptReplacesExistingTurnsWithRefreshedTranscript() async {
        let session = makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
        let repository = StubSessionManagementRepository(
            sessions: [session],
            transcripts: [
                "codex::2": [TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)]
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "codex::2")
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        repository.transcripts["codex::2"] = [
            TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil),
            TranscriptTurn(id: "t2", role: .assistant, text: "Done", timestamp: nil)
        ]
        repository.resetLoadTranscriptExpectation()

        store.refreshSelectedSessionTranscript()
        XCTAssertTrue(store.isRefreshingTranscript)
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        XCTAssertFalse(store.isRefreshingTranscript)
        XCTAssertEqual(
            store.transcriptState,
            .loaded([
                TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil),
                TranscriptTurn(id: "t2", role: .assistant, text: "Done", timestamp: nil)
            ])
        )
    }

    @MainActor
    func testRefreshSelectedSessionTranscriptReplacesExistingTurnsWhenRefreshIsShorter() async {
        let session = makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")
        let repository = StubSessionManagementRepository(
            sessions: [session],
            transcripts: [
                "codex::2": [
                    TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil),
                    TranscriptTurn(id: "t2", role: .assistant, text: "Old trailing content", timestamp: nil)
                ]
            ]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.selectSession(id: "codex::2")
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        repository.transcripts["codex::2"] = [
            TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)
        ]
        repository.resetLoadTranscriptExpectation()

        store.refreshSelectedSessionTranscript()
        await fulfillment(of: [repository.loadTranscriptExpectation], timeout: 1.0)

        XCTAssertEqual(
            store.transcriptState,
            .loaded([
                TranscriptTurn(id: "t1", role: .user, text: "Investigate", timestamp: nil)
            ])
        )
    }

    @MainActor
    func testRefreshSelectedSessionTranscriptDoesNothingWithoutSelection() async {
        let repository = StubSessionManagementRepository(
            sessions: [makeManagedSession(id: "codex::2", source: .codex, title: "Crash audit", projectPath: "/tmp/b")]
        )
        let store = SessionManagementStore(repository: repository)

        store.refreshIfNeeded()
        await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)
        store.refreshSelectedSessionTranscript()

        XCTAssertFalse(store.isRefreshingTranscript)
        XCTAssertEqual(store.transcriptState, .idle)
        XCTAssertEqual(repository.loadTranscriptExpectation.expectedFulfillmentCount, 1)
    }
}

private final class StubSessionManagementRepository: SessionManagementRepositorying {
    static var onLoadManagedSessions: (() -> Void)?
    static var onLoadTranscript: ((String) -> Void)?

    var sessions: [ManagedSessionSummary] = []
    var partialManagedSessionUpdates: [ManagedSessionsPartialUpdate] = []
    var onPartialManagedSessions: ((ManagedSessionsPartialUpdate) -> Void)?
    var transcripts: [String: [TranscriptTurn]] = [:]
    var partialTranscriptBatches: [String: [[TranscriptTurn]]] = [:]
    var onPartialTranscript: (([TranscriptTurn]) -> Void)?
    var loadManagedSessionsError: Error?
    var loadTranscriptError: Error?
    private(set) var loadManagedSessionsCallCount = 0
    private(set) var loadManagedSessionsExpectation = XCTestExpectation(description: "loadManagedSessions")
    private(set) var loadTranscriptExpectation = XCTestExpectation(description: "loadTranscript")

    init(
        sessions: [ManagedSessionSummary] = [],
        partialManagedSessions: [[ManagedSessionSummary]] = [],
        partialManagedSessionUpdates: [ManagedSessionsPartialUpdate] = [],
        transcripts: [String: [TranscriptTurn]] = [:],
        partialTranscriptBatches: [String: [[TranscriptTurn]]] = [:],
        loadManagedSessionsError: Error? = nil,
        loadTranscriptError: Error? = nil
    ) {
        self.sessions = sessions
        self.partialManagedSessionUpdates = partialManagedSessionUpdates.isEmpty
            ? partialManagedSessions.map {
                ManagedSessionsPartialUpdate(
                    sessions: $0,
                    loadedSources: Set($0.map(\.source))
                )
            }
            : partialManagedSessionUpdates
        self.transcripts = transcripts
        self.partialTranscriptBatches = partialTranscriptBatches
        self.loadManagedSessionsError = loadManagedSessionsError
        self.loadTranscriptError = loadTranscriptError
        loadManagedSessionsExpectation.expectedFulfillmentCount = 1
        loadTranscriptExpectation.expectedFulfillmentCount = 1
    }

    func loadManagedSessions(enabledSources: Set<AgentSource>) throws -> [ManagedSessionSummary] {
        try loadManagedSessions(enabledSources: enabledSources, onPartialUpdate: { _ in })
    }

    func loadManagedSessions(
        enabledSources: Set<AgentSource>,
        onPartialUpdate: @escaping @Sendable (ManagedSessionsPartialUpdate) -> Void
    ) throws -> [ManagedSessionSummary] {
        loadManagedSessionsCallCount += 1
        Self.onLoadManagedSessions?()
        for update in partialManagedSessionUpdates {
            onPartialUpdate(update)
            onPartialManagedSessions?(update)
        }
        loadManagedSessionsExpectation.fulfill()
        if let loadManagedSessionsError {
            throw loadManagedSessionsError
        }
        return sessions
    }

    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn] {
        try loadTranscript(for: session) { _ in }
    }

    func loadTranscript(
        for session: ManagedSessionSummary,
        onPartialUpdate: @escaping @Sendable ([TranscriptTurn]) -> Void
    ) throws -> [TranscriptTurn] {
        Self.onLoadTranscript?(session.id)
        for batch in partialTranscriptBatches[session.id] ?? [] {
            onPartialUpdate(batch)
            onPartialTranscript?(batch)
        }
        loadTranscriptExpectation.fulfill()
        if let loadTranscriptError {
            throw loadTranscriptError
        }
        return transcripts[session.id] ?? []
    }

    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction {
        switch session.source {
        case .openCode:
            return .openCode(command: "opencode resume \(session.rawSessionID)")
        case .codex:
            return .codex(command: "codex resume \(session.rawSessionID)")
        case .all:
            return .codex(command: "")
        case .claudeCode:
            return .codex(command: "")
        }
    }

    func resetLoadManagedSessionsExpectation() {
        loadManagedSessionsExpectation = XCTestExpectation(description: "loadManagedSessions")
        loadManagedSessionsExpectation.expectedFulfillmentCount = 1
    }

    func resetLoadTranscriptExpectation(expectedFulfillmentCount: Int = 1) {
        loadTranscriptExpectation = XCTestExpectation(description: "loadTranscript")
        loadTranscriptExpectation.expectedFulfillmentCount = expectedFulfillmentCount
    }

    static func resetHooks() {
        onLoadManagedSessions = nil
        onLoadTranscript = nil
    }
}

private func makeManagedSession(
    id: String,
    source: AgentSource,
    title: String,
    projectPath: String,
    updatedAt: Date = Date(timeIntervalSince1970: 2_000)
) -> ManagedSessionSummary {
    ManagedSessionSummary(
        id: id,
        source: source,
        rawSessionID: id.components(separatedBy: "::").dropFirst().first ?? id,
        title: title,
        projectPath: projectPath,
        projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
        subtitle: source.rawValue,
        updatedAt: updatedAt,
        transcriptURL: nil
    )
}
