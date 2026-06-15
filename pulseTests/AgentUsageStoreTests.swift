import XCTest
@testable import Pulse

final class AgentUsageStoreTests: XCTestCase {
    func testRefreshAllLoadsBothSnapshotsAndClearsPreviousDetailCache() {
        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1")])
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1")])
        repository.codexDetail = CodexSessionDetail(threadID: "cx_1", edges: [], goals: [])

        let store = AgentUsageStore(repository: repository)

        store.ensureCodexDetailLoaded(for: "cx_1")
        XCTAssertEqual(repository.codexDetailLoadCount, 1)

        store.refreshAll()

        XCTAssertEqual(repository.openCodeLoadCount, 1)
        XCTAssertEqual(repository.openCodeBucketLoadCount, 1)
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

    func testRefreshAllLoadsBucketsAlongsideCumulative() {
        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1")])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(sessionID: "oc_1", day: 20000,
                inputTokens: 50, outputTokens: 25, reasoningTokens: 5,
                cacheReadTokens: 500, cacheWriteTokens: 2, cost: 0.01)
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        XCTAssertEqual(repository.openCodeLoadCount, 1)
        XCTAssertEqual(repository.openCodeBucketLoadCount, 1)
        XCTAssertEqual(store.state.openCodeDailyBuckets.count, 1)
        XCTAssertEqual(store.state.openCodeCumulativeSnapshot.sessions.count, 1)
    }

    func testDerivedDataUsesBucketsForTodayAndCumulativeForAllTime() {
        let todayDay = Int(Date().timeIntervalSince1970 * 1000) / 86400000

        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            makeOpenCodeSession(id: "ses_1", tokens: 1000)
        ])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(sessionID: "ses_1", day: todayDay,
                inputTokens: 10, outputTokens: 5, reasoningTokens: 1,
                cacheReadTokens: 20, cacheWriteTokens: 2, cost: 0.001)
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let allTimeSelection = AgentUsageSelection(
            source: .openCode, timeRange: .allTime,
            projectDirectory: nil, sessionID: nil, modelGroupBy: .model)
        let allTimeData = store.derivedData(for: allTimeSelection)
        XCTAssertEqual(allTimeData.summary.totalTokens, 1000)

        let todaySelection = AgentUsageSelection(
            source: .openCode, timeRange: .today,
            projectDirectory: nil, sessionID: nil, modelGroupBy: .model)
        let todayData = store.derivedData(for: todaySelection)
        XCTAssertEqual(todayData.summary.totalTokens, 38)
    }
}

private func makeOpenCodeSession(id: String, tokens: Int = 100) -> OpenCodeSessionRecord {
    OpenCodeSessionRecord(
        id: id,
        title: "Session \(id)",
        directory: "/Users/zyao/Desktop/pulse",
        agent: "build",
        modelProviderID: "opencode",
        modelID: "model-a",
        modelVariant: nil,
        inputTokens: tokens,
        outputTokens: 0,
        reasoningTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        cost: 0,
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: Date(timeIntervalSince1970: 2000)
    )
}

private func makeCodexSession(id: String, tokens: Int = 100) -> CodexSessionRecord {
    CodexSessionRecord(
        id: id,
        title: "Session \(id)",
        cwd: "/Users/zyao/Desktop/pulse",
        model: "gpt-5",
        modelProvider: "openai",
        tokensUsed: tokens,
        reasoningEffort: "",
        threadSource: "primary",
        agentNickname: nil,
        agentRole: nil,
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: Date(timeIntervalSince1970: 2000)
    )
}

private final class StubAgentUsageRepository: AgentUsageRepositorying {
    var openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/opencode.db")
    var codexDatabaseURL: URL? = URL(fileURLWithPath: "/tmp/codex.db")

    var openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [])
    var openCodeDailyBuckets: [OpenCodeDailyBucket] = []
    var codexSnapshot = CodexUsageSnapshot(sessions: [])
    var codexDetail = CodexSessionDetail(threadID: "", edges: [], goals: [])

    var openCodeLoadCount = 0
    var openCodeBucketLoadCount = 0
    var codexLoadCount = 0
    var codexDetailLoadCount = 0

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot {
        openCodeLoadCount += 1
        return openCodeCumulativeSnapshot
    }

    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] {
        openCodeBucketLoadCount += 1
        return openCodeDailyBuckets
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
