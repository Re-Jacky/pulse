import XCTest
@testable import Pulse

final class AgentUsageViewDataTests: XCTestCase {
    func testSelectionScopeUsesSessionOnlyWhenProjectAndSessionExistAndSourceIsNotAll() {
        let sessionSelection = AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: "/tmp/pulse",
            sessionID: "thread_1",
            modelGroupBy: .model
        )

        XCTAssertEqual(
            sessionSelection.scope,
            .session(projectDirectory: "/tmp/pulse", sessionID: "thread_1")
        )
        XCTAssertTrue(sessionSelection.isSessionScope)

        let missingSessionSelection = AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: "/tmp/pulse",
            sessionID: nil,
            modelGroupBy: .model
        )

        XCTAssertEqual(missingSessionSelection.scope, .project(directory: "/tmp/pulse"))
        XCTAssertFalse(missingSessionSelection.isSessionScope)

        let allSourceSelection = AgentUsageSelection(
            source: .all,
            timeRange: .today,
            projectDirectory: "/tmp/pulse",
            sessionID: "thread_1",
            modelGroupBy: .model
        )

        XCTAssertEqual(allSourceSelection.scope, .project(directory: "/tmp/pulse"))
        XCTAssertFalse(allSourceSelection.isSessionScope)
    }

    func testSelectionScopeUsesAllProjectsWhenProjectIsNil() {
        let selection = AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: "thread_1",
            modelGroupBy: .provider
        )

        XCTAssertEqual(selection.scope, .allProjects)
        XCTAssertFalse(selection.isSessionScope)
    }

    func testLoadedStateEmptyStartsWithEmptyCodexDetailCache() {
        XCTAssertEqual(AgentUsageLoadedState.empty.codexDetailCache, [:])
        XCTAssertEqual(AgentUsageLoadedState.empty.refreshGeneration, 0)
    }

    func testDerivedDataForAllSourceMergesSummariesAndShowsTokenFlow() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1", tokens: 120)]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 80)]),
                codexDailyBuckets: [],
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
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "thread_1", tokens: 80)]),
                codexDailyBuckets: [],
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

    func testDerivedDataForCodexPreservesDetailedSummaryFields() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [
                    makeCodexSession(
                        id: "thread_1",
                        tokens: 120,
                        inputTokens: 100,
                        outputTokens: 20,
                        reasoningTokens: 5,
                        cacheReadTokens: 40
                    )
                ]),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 120)
        XCTAssertEqual(data.summary.inputTokens, 100)
        XCTAssertEqual(data.summary.outputTokens, 20)
        XCTAssertEqual(data.summary.reasoningTokens, 5)
        XCTAssertEqual(data.summary.cacheReadTokens, 40)
        XCTAssertNil(data.summary.cacheWriteTokens)
    }

    func testDerivedDataForAllTimeCarriesMultiDayBucketSizeWhenRangeIsCompressed() {
        let now = Date()
        let oldestDate = Calendar.current.date(byAdding: .day, value: -32, to: now) ?? now
        let recentDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    makeOpenCodeSession(id: "oc_old", tokens: 120, updatedAt: oldestDate),
                    makeOpenCodeSession(id: "oc_recent", tokens: 80, updatedAt: recentDate)
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
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

        XCTAssertFalse(data.tokenFlowData.isEmpty)
        XCTAssertEqual(data.tokenFlowData.first?.bucketSizeDays, 2)
    }

    func testDerivedDataForAllSourceTokenFlowFallsBackPerSourceWhenOnlyOneHasBuckets() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let todayDay = Int(today.timeIntervalSince1970 * 1000) / 86400000

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    makeOpenCodeSession(id: "oc_1", tokens: 999, updatedAt: now)
                ]),
                openCodeDailyBuckets: [
                    OpenCodeDailyBucket(
                        sessionID: "oc_1",
                        day: todayDay,
                        inputTokens: 10,
                        outputTokens: 5,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        cost: 0
                    )
                ],
                codexSnapshot: CodexUsageSnapshot(sessions: [
                    makeCodexSession(
                        id: "cx_1",
                        tokens: 80,
                        updatedAt: now
                    )
                ]),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .last7Days,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 95)
        XCTAssertEqual(data.tokenFlowData.reduce(0) { $0 + $1.totalTokens }, 95)
    }
}

private func makeOpenCodeSession(id: String, tokens: Int = 100, updatedAt: Date = Date(timeIntervalSince1970: 2000)) -> OpenCodeSessionRecord {
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
        updatedAt: updatedAt
    )
}

private func makeCodexSession(
    id: String,
    tokens: Int = 100,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    cacheReadTokens: Int? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 2000)
) -> CodexSessionRecord {
    CodexSessionRecord(
        id: id,
        title: "Session \(id)",
        cwd: "/Users/zyao/Desktop/pulse",
        model: "gpt-5",
        modelProvider: "openai",
        tokensUsed: tokens,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        cacheReadTokens: cacheReadTokens,
        reasoningEffort: "",
        threadSource: "primary",
        agentNickname: nil,
        agentRole: nil,
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: updatedAt
    )
}

private final class StubRepository: AgentUsageRepositorying {
    var openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/opencode.db")
    var codexDatabaseURL: URL? = URL(fileURLWithPath: "/tmp/codex.db")
    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot { OpenCodeUsageSnapshot(sessions: []) }
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] { [] }
    func loadCodexSnapshot() throws -> CodexUsageSnapshot { CodexUsageSnapshot(sessions: []) }
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket] { [] }
    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail { CodexSessionDetail(threadID: threadID, edges: [], goals: []) }
}
