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
