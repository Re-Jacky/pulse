import XCTest
import SQLite3
@testable import Pulse

final class AgentUsageStoreTests: XCTestCase {
    func testCodexResolveDatabaseURLPrefersActiveSQLiteSubdirectoryDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let sqliteDir = codexRoot.appendingPathComponent("sqlite")
        let staleRootDB = codexRoot.appendingPathComponent("state_5.sqlite")
        let activeSQLiteDB = sqliteDir.appendingPathComponent("state_5.sqlite")
        let activeSQLiteWAL = sqliteDir.appendingPathComponent("state_5.sqlite-wal")

        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: activeSQLiteDB.path, contents: Data([0x01, 0x02])))
        XCTAssertTrue(FileManager.default.createFile(atPath: staleRootDB.path, contents: Data([0x01])))
        XCTAssertTrue(FileManager.default.createFile(atPath: activeSQLiteWAL.path, contents: Data([0x03, 0x04, 0x05])))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: activeSQLiteDB.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: staleRootDB.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: activeSQLiteWAL.path)

        let chosen = CodexUsageQuery.resolveDatabaseURL(
            environment: [:],
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(
            chosen?.resolvingSymlinksInPath().path,
            activeSQLiteDB.resolvingSymlinksInPath().path
        )
        try? FileManager.default.removeItem(at: root)
    }

    func testCodexLoadSnapshotReadsRowsStillInWAL() throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsageQuery-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("shm"))
        }

        let writer = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(writer) }

        try execute(writer, sql: "pragma journal_mode=WAL;")
        try execute(writer, sql: """
        create table threads (
            id text primary key,
            title text,
            cwd text not null,
            model text,
            model_provider text not null,
            tokens_used integer not null default 0,
            reasoning_effort text,
            thread_source text,
            agent_nickname text,
            agent_role text,
            created_at_ms integer,
            updated_at_ms integer,
            archived integer
        );
        """)

        try execute(writer, sql: """
        insert into threads (
            id, title, cwd, model, model_provider, tokens_used,
            reasoning_effort, thread_source, agent_nickname, agent_role,
            created_at_ms, updated_at_ms, archived
        ) values (
            'thread_1', 'Existing', '/tmp/project', 'gpt-5', 'openai', 100,
            '', 'user', null, null, 1000, 2000, 0
        );
        """)
        try execute(writer, sql: "pragma wal_checkpoint(truncate);")
        try execute(writer, sql: """
        insert into threads (
            id, title, cwd, model, model_provider, tokens_used,
            reasoning_effort, thread_source, agent_nickname, agent_role,
            created_at_ms, updated_at_ms, archived
        ) values (
            'thread_2', 'Fresh', '/tmp/project', 'gpt-5', 'openai', 250,
            '', 'user', null, null, 3000, 4000, 0
        );
        """)

        let snapshot = try CodexUsageQuery.loadSnapshot(databaseURL: databaseURL)

        XCTAssertEqual(snapshot.sessions.map(\.id), ["thread_2", "thread_1"])
        XCTAssertEqual(snapshot.summary(for: .allProjects).totalTokens, 350)
    }

    func testCodexLoadSnapshotIncludesArchivedThreadsForHistory() throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("CodexArchived-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let writer = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(writer) }

        try execute(writer, sql: """
        create table threads (
            id text primary key,
            title text,
            cwd text not null,
            model text,
            model_provider text not null,
            tokens_used integer not null default 0,
            reasoning_effort text,
            thread_source text,
            agent_nickname text,
            agent_role text,
            created_at_ms integer,
            updated_at_ms integer,
            archived integer
        );
        """)

        try execute(writer, sql: """
        insert into threads values
        ('thread_live', 'Live', '/tmp/project', 'gpt-5', 'openai', 100, '', 'user', null, null, 1000, 2000, 0),
        ('thread_archived', 'Archived', '/tmp/project', 'gpt-5', 'openai', 250, '', 'user', null, null, 3000, 4000, 1);
        """)

        let snapshot = try CodexUsageQuery.loadSnapshot(databaseURL: databaseURL)

        XCTAssertEqual(snapshot.sessions.map(\.id), ["thread_archived", "thread_live"])
        XCTAssertEqual(snapshot.summary(for: .allProjects).totalTokens, 350)
    }

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

    func testRefreshAllStillLoadsCodexWhenOpenCodeFails() {
        let repository = StubAgentUsageRepository()
        repository.openCodeError = .databaseNotFound(path: "/tmp/missing-opencode.db")
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 321)])

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        XCTAssertEqual(store.state.codexSnapshot.sessions.map(\.id), ["cx_1"])
        XCTAssertEqual(store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )).summary.totalTokens, 321)
        XCTAssertEqual(store.lastError, .openCode(.databaseNotFound(path: "/tmp/missing-opencode.db")))
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
            codexDailyBuckets: [],
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

    func testDerivedDataUsesBucketsForLast7DaysIncludingToday() {
        let todayDay = Int(Date().timeIntervalSince1970 * 1000) / 86400000

        let repository = StubAgentUsageRepository()
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(id: "cx_1", tokens: 999, updatedAt: Date())
        ])
        repository.codexDailyBuckets = [
            CodexDailyBucket(
                sessionID: "cx_1",
                day: todayDay,
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 40,
                totalTokens: 120
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let selection = AgentUsageSelection(
            source: .codex,
            timeRange: .last7Days,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )
        let data = store.derivedData(for: selection)

        XCTAssertEqual(data.summary.totalTokens, 120)
        XCTAssertEqual(data.summary.inputTokens, 100)
        XCTAssertEqual(data.summary.outputTokens, 20)
        XCTAssertEqual(data.summary.reasoningTokens, 5)
        XCTAssertEqual(data.summary.cacheReadTokens, 40)
    }

    func testDerivedDataUsesBucketsForLast30DaysIncludingToday() {
        let todayDay = Int(Date().timeIntervalSince1970 * 1000) / 86400000

        let repository = StubAgentUsageRepository()
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(id: "cx_1", tokens: 999, updatedAt: Date())
        ])
        repository.codexDailyBuckets = [
            CodexDailyBucket(
                sessionID: "cx_1",
                day: todayDay,
                inputTokens: 70,
                outputTokens: 15,
                reasoningTokens: 4,
                cacheReadTokens: 11,
                totalTokens: 90
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let selection = AgentUsageSelection(
            source: .codex,
            timeRange: .last30Days,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )
        let data = store.derivedData(for: selection)

        XCTAssertEqual(data.summary.totalTokens, 90)
        XCTAssertEqual(data.summary.inputTokens, 70)
        XCTAssertEqual(data.summary.outputTokens, 15)
        XCTAssertEqual(data.summary.reasoningTokens, 4)
        XCTAssertEqual(data.summary.cacheReadTokens, 11)
    }

    func testCodexLoadDailyBucketsSplitsCrossDaySessionFromTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let sessionDir = home.appendingPathComponent(".codex/sessions/2026/06/16")
        let transcriptURL = sessionDir.appendingPathComponent("rollout-test.jsonl")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let transcript = """
        {"timestamp":"2026-06-16T23:50:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/Users/zyao/Desktop/pulse"}}
        {"timestamp":"2026-06-16T23:50:01Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"2026-06-16T23:55:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        {"timestamp":"2026-06-17T00:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":190,"cached_input_tokens":80,"output_tokens":30,"reasoning_output_tokens":8,"total_tokens":220}}}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let buckets = try CodexUsageQuery.loadDailyBuckets(
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(
            buckets,
            [
                CodexDailyBucket(
                    sessionID: "thread_1",
                    day: 20620,
                    inputTokens: 100,
                    outputTokens: 20,
                    reasoningTokens: 5,
                    cacheReadTokens: 40,
                    totalTokens: 120
                ),
                CodexDailyBucket(
                    sessionID: "thread_1",
                    day: 20621,
                    inputTokens: 90,
                    outputTokens: 10,
                    reasoningTokens: 3,
                    cacheReadTokens: 40,
                    totalTokens: 100
                )
            ]
        )

        try? FileManager.default.removeItem(at: root)
    }

    func testCodexLoadDailyBucketsPreservesNativeTotalTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let sessionDir = home.appendingPathComponent(".codex/sessions/2026/06/16")
        let transcriptURL = sessionDir.appendingPathComponent("native-total-test.jsonl")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let transcript = """
        {"timestamp":"2026-06-16T23:55:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/Users/zyao/Desktop/pulse"}}
        {"timestamp":"2026-06-16T23:56:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let buckets = try CodexUsageQuery.loadDailyBuckets(
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].totalTokens, 120)
        XCTAssertEqual(buckets[0].inputTokens, 100)
        XCTAssertEqual(buckets[0].outputTokens, 20)
        XCTAssertEqual(buckets[0].reasoningTokens, 5)
        XCTAssertEqual(buckets[0].cacheReadTokens, 40)

        try? FileManager.default.removeItem(at: root)
    }

    func testDerivedDataUsesCodexBucketsForTodayInsteadOfSessionUpdatedAt() {
        let todayDay = Int(Date().timeIntervalSince1970 * 1000) / 86400000

        let repository = StubAgentUsageRepository()
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(
                id: "cx_1",
                tokens: 500,
                updatedAt: Date()
            )
        ])
        repository.codexDailyBuckets = [
            CodexDailyBucket(
                sessionID: "cx_1",
                day: todayDay - 1,
                inputTokens: 400,
                outputTokens: 60,
                reasoningTokens: 20,
                cacheReadTokens: 20,
                totalTokens: 500
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let todaySelection = AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )
        let todayData = store.derivedData(for: todaySelection)

        XCTAssertEqual(todayData.summary.totalTokens, 0)
    }

    func testDerivedDataUsesCodexDetailedBucketFieldsForToday() {
        let todayDay = Int(Date().timeIntervalSince1970 * 1000) / 86400000

        let repository = StubAgentUsageRepository()
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(
                id: "cx_1",
                tokens: 999,
                updatedAt: Date()
            )
        ])
        repository.codexDailyBuckets = [
            CodexDailyBucket(
                sessionID: "cx_1",
                day: todayDay,
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 40,
                totalTokens: 120
            ),
            CodexDailyBucket(
                sessionID: "cx_1",
                day: todayDay,
                inputTokens: 90,
                outputTokens: 10,
                reasoningTokens: 3,
                cacheReadTokens: 40,
                totalTokens: 100
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let data = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 220)
        XCTAssertEqual(data.summary.inputTokens, 190)
        XCTAssertEqual(data.summary.outputTokens, 30)
        XCTAssertEqual(data.summary.reasoningTokens, 8)
        XCTAssertEqual(data.summary.cacheReadTokens, 80)
        XCTAssertNil(data.summary.cacheWriteTokens)
    }

    func testRefreshAllAsyncPublishesLoadingThenCompletes() async throws {
        let repository = BlockingAgentUsageRepository()
        let store = AgentUsageStore(repository: repository)

        store.refreshAllAsync()

        await fulfillment(of: [repository.didStartLoading], timeout: 1.0)
        XCTAssertTrue(store.isLoading)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.state.refreshGeneration, 0)

        repository.finishLoading()

        try await waitUntil(timeout: 1.0) {
            store.isLoading == false && store.state.refreshGeneration == 1
        }

        XCTAssertEqual(store.state.openCodeCumulativeSnapshot.sessions.map(\.id), ["oc_async"])
        XCTAssertEqual(store.state.codexSnapshot.sessions.map(\.id), ["cx_async"])
    }
}

private func openWritableDatabase(_ url: URL) throws -> OpaquePointer? {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw NSError(domain: "AgentUsageStoreTests", code: 1)
    }
    return db
}

private func execute(_ db: OpaquePointer?, sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AgentUsageStoreTests", code: 2)
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
    makeCodexSession(id: id, tokens: tokens, updatedAt: Date(timeIntervalSince1970: 2000))
}

private func makeCodexSession(
    id: String,
    tokens: Int = 100,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    cacheReadTokens: Int? = nil,
    updatedAt: Date
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

private final class StubAgentUsageRepository: AgentUsageRepositorying {
    var openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/opencode.db")
    var codexDatabaseURL: URL? = URL(fileURLWithPath: "/tmp/codex.db")

    var openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [])
    var openCodeDailyBuckets: [OpenCodeDailyBucket] = []
    var codexSnapshot = CodexUsageSnapshot(sessions: [])
    var codexDailyBuckets: [CodexDailyBucket] = []
    var codexDetail = CodexSessionDetail(threadID: "", edges: [], goals: [])
    var openCodeError: OpenCodeUsageQuery.QueryError?
    var openCodeDailyBucketError: OpenCodeUsageQuery.QueryError?
    var codexError: CodexUsageQuery.QueryError?

    var openCodeLoadCount = 0
    var openCodeBucketLoadCount = 0
    var codexLoadCount = 0
    var codexBucketLoadCount = 0
    var codexDetailLoadCount = 0

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot {
        openCodeLoadCount += 1
        if let openCodeError { throw openCodeError }
        return openCodeCumulativeSnapshot
    }

    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] {
        openCodeBucketLoadCount += 1
        if let openCodeDailyBucketError { throw openCodeDailyBucketError }
        return openCodeDailyBuckets
    }

    func loadCodexSnapshot() throws -> CodexUsageSnapshot {
        codexLoadCount += 1
        if let codexError { throw codexError }
        return codexSnapshot
    }

    func loadCodexDailyBuckets() throws -> [CodexDailyBucket] {
        codexBucketLoadCount += 1
        if let codexError { throw codexError }
        return codexDailyBuckets
    }

    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail {
        codexDetailLoadCount += 1
        return codexDetail
    }
}

private final class BlockingAgentUsageRepository: AgentUsageRepositorying {
    let openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/opencode.db")
    let codexDatabaseURL: URL? = URL(fileURLWithPath: "/tmp/codex.db")
    let didStartLoading = XCTestExpectation(description: "started loading")

    private let semaphore = DispatchSemaphore(value: 0)

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot {
        didStartLoading.fulfill()
        semaphore.wait()
        return OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_async")])
    }

    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] {
        []
    }

    func loadCodexSnapshot() throws -> CodexUsageSnapshot {
        CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_async")])
    }

    func loadCodexDailyBuckets() throws -> [CodexDailyBucket] {
        []
    }

    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail {
        CodexSessionDetail(threadID: threadID, edges: [], goals: [])
    }

    func finishLoading() {
        semaphore.signal()
    }
}

private func waitUntil(timeout: TimeInterval, condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Condition not met within \(timeout) seconds")
}
