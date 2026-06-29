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
        let todayDay = agentUsageDayIdentifier(for: today)

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
                        requestCount: 0,
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

    func testDataSourceDescriptionForCodexMentionsDatabaseAndTranscripts() {
        let description = AgentUsageDataSourceDescription.message(
            for: .codex,
            openCodeDatabaseURL: URL(fileURLWithPath: "/Users/zyao/.local/share/opencode/opencode.db"),
            codexDatabaseURL: URL(fileURLWithPath: "/Users/zyao/.codex/sqlite/state_5.sqlite")
        )

        XCTAssertEqual(
            description,
            "Pulse reads Codex session metadata from /Users/zyao/.codex/sqlite/state_5.sqlite and derives token usage from local transcripts under ~/.codex when you refresh the panel."
        )
    }

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

    func testDerivedDataForCodexProjectRequestCountExcludesSubagentBuckets() {
        let store = AgentUsageStore(repository: StubRepository())
        let now = Date()
        let todayDay = agentUsageDayIdentifier(for: now)
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [
                    makeCodexSession(id: "primary", tokens: 100),
                    CodexSessionRecord(
                        id: "subagent",
                        title: "Subagent",
                        cwd: "/Users/zyao/Desktop/pulse",
                        model: "gpt-5",
                        modelProvider: "openai",
                        tokensUsed: 50,
                        inputTokens: 40,
                        outputTokens: 10,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        reasoningEffort: "",
                        threadSource: "subagent",
                        agentNickname: nil,
                        agentRole: nil,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    )
                ]),
                codexDailyBuckets: [
                    CodexDailyBucket(
                        sessionID: "primary",
                        day: todayDay,
                        inputTokens: 80,
                        outputTokens: 20,
                        reasoningTokens: 0,
                        cacheReadTokens: 40,
                        totalTokens: 100,
                        requestCount: 5,
                        latestActivityAt: now
                    ),
                    CodexDailyBucket(
                        sessionID: "subagent",
                        day: todayDay,
                        inputTokens: 40,
                        outputTokens: 10,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        totalTokens: 50,
                        requestCount: 7,
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
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: nil,
            modelGroupBy: .model
        ))
        XCTAssertEqual(data.summary.requestCount, 5)
    }

    func testDerivedDataForOpenCodeRangedSessionUsesBucketActivityForSelectedCompoundSession() {
        let now = Date()
        let activityAt = now.addingTimeInterval(-60)
        let day = agentUsageDayIdentifier(for: now)
        let compoundID = "oc_1::opencode::model-a::"

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    makeOpenCodeSession(id: "oc_1", tokens: 999, updatedAt: now.addingTimeInterval(-3600))
                ]),
                openCodeDailyBuckets: [
                    OpenCodeDailyBucket(
                        sessionID: "oc_1",
                        day: day,
                        modelProviderID: "opencode",
                        modelID: "model-a",
                        modelVariant: nil,
                        inputTokens: 80,
                        outputTokens: 20,
                        reasoningTokens: 5,
                        cacheReadTokens: 40,
                        cacheWriteTokens: 3,
                        requestCount: 2,
                        cost: 0.01,
                        latestActivityAt: activityAt
                    )
                ],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .today,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: compoundID,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.selectedOpenCodeSession?.id, compoundID)
        XCTAssertEqual(data.selectedOpenCodeSession?.updatedAt, activityAt)
    }

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
        XCTAssertEqual(hitRatePill?.valueText, "38%")
    }

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
                        inputTokens: 0,
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

    func testModelBreakdownRowsDeduplicatesCompoundSessionIDsForAllTime() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "ses_1::anthropic::claude-sonnet-4-20250514::",
                        title: "Multi-model session",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: nil,
                        inputTokens: 100,
                        outputTokens: 50,
                        reasoningTokens: 10,
                        cacheReadTokens: 20,
                        cacheWriteTokens: 5,
                        requestCount: 3,
                        cost: 0.01,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    ),
                    OpenCodeSessionRecord(
                        id: "ses_1::anthropic::claude-sonnet-4-20250514::thinking",
                        title: "Multi-model session",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: "thinking",
                        inputTokens: 200,
                        outputTokens: 80,
                        reasoningTokens: 50,
                        cacheReadTokens: 30,
                        cacheWriteTokens: 8,
                        requestCount: 5,
                        cost: 0.03,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 3000)
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

        let uniqueIDs = Set(data.modelBreakdownRows.map(\.id))
        XCTAssertEqual(data.modelBreakdownRows.count, uniqueIDs.count, "modelBreakdownRows contains duplicate ids")
        XCTAssertEqual(data.modelBreakdownRows.count, 2, "Should have two distinct model entries (default + thinking)")
        let defaultRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514" }
        let thinkingRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514 (thinking)" }
        XCTAssertNotNil(defaultRow)
        XCTAssertNotNil(thinkingRow)
        XCTAssertEqual(defaultRow?.id, "anthropic::claude-sonnet-4-20250514::")
        XCTAssertEqual(thinkingRow?.id, "anthropic::claude-sonnet-4-20250514::thinking")
    }

    func testModelBreakdownRowsDeduplicatesVariantBucketsForRangedTime() {
        let todayDay = agentUsageDayIdentifier(for: Date())

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "ses_1",
                        title: "Session ses_1",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: nil,
                        inputTokens: 500,
                        outputTokens: 0,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 0,
                        cost: 0,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ]),
                openCodeDailyBuckets: [
                    OpenCodeDailyBucket(
                        sessionID: "ses_1",
                        day: todayDay,
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: nil,
                        inputTokens: 100,
                        outputTokens: 50,
                        reasoningTokens: 10,
                        cacheReadTokens: 20,
                        cacheWriteTokens: 5,
                        requestCount: 3,
                        cost: 0.01
                    ),
                    OpenCodeDailyBucket(
                        sessionID: "ses_1",
                        day: todayDay,
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: "thinking",
                        inputTokens: 200,
                        outputTokens: 80,
                        reasoningTokens: 50,
                        cacheReadTokens: 30,
                        cacheWriteTokens: 8,
                        requestCount: 5,
                        cost: 0.03
                    )
                ],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        let uniqueIDs = Set(data.modelBreakdownRows.map(\.id))
        XCTAssertEqual(data.modelBreakdownRows.count, uniqueIDs.count, "modelBreakdownRows contains duplicate ids for ranged time")
        XCTAssertEqual(data.modelBreakdownRows.count, 2, "Should have two distinct model entries for ranged time (default + thinking)")
        let defaultRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514" }
        let thinkingRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514 (thinking)" }
        XCTAssertNotNil(defaultRow)
        XCTAssertNotNil(thinkingRow)
        XCTAssertEqual(defaultRow?.id, "anthropic::claude-sonnet-4-20250514::")
        XCTAssertEqual(thinkingRow?.id, "anthropic::claude-sonnet-4-20250514::thinking")
    }

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
        requestCount: 0,
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
    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail {
        CodexSessionDetail(threadID: threadID, edges: [], goals: [])
    }
}
