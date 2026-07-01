import XCTest
import SQLite3
import Darwin
@testable import Pulse

final class AgentUsageStoreTests: XCTestCase {
    func testAgentUsageDayIntervalForPresetTodayUsesOneLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_720_558_400)

        let interval = agentUsageDayInterval(for: AgentDateSelection.preset(.today), now: now, calendar: calendar)

        XCTAssertEqual(interval?.count, 1)
    }

    func testAgentUsageDayIntervalForSingleDayMatchesSelectedDay() {
        let day = 19_900

        let interval = agentUsageDayInterval(for: AgentDateSelection.singleDay(day), now: Date(), calendar: .gregorianUTCForTests)

        XCTAssertEqual(interval, day..<(day + 1))
    }

    func testAgentUsageDayIntervalForRangeNormalizesReversedEndpoints() {
        let interval = agentUsageDayInterval(for: AgentDateSelection.dayRange(startDay: 20, endDay: 18), now: Date(), calendar: .gregorianUTCForTests)

        XCTAssertEqual(interval, 18..<21)
    }

    func testAgentUsageDayIntervalForAllTimeReturnsNil() {
        XCTAssertNil(agentUsageDayInterval(for: AgentDateSelection.preset(.allTime), now: Date(), calendar: .gregorianUTCForTests))
    }

    func testPresetShortcutAndEquivalentExplicitRangeProduceSameSummaryForToday() {
        let today = agentUsageDayIdentifier(for: Date())
        let store = makeStoreWithLoadedState(
            openCodeBuckets: [openCodeBucket(day: today, totalTokens: 42, sessionID: "oc-1")],
            codexBuckets: []
        )

        let preset = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .preset(.today),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let explicit = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .singleDay(today),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(preset.summary.totalTokens, explicit.summary.totalTokens)
    }

    func testTodayEquivalentExplicitSelectionHidesAllSourceTokenFlow() {
        let today = agentUsageDayIdentifier(for: Date())
        let store = makeStoreWithLoadedState(
            openCodeBuckets: [openCodeBucket(day: today, totalTokens: 42, sessionID: "oc-1")],
            codexBuckets: [
                CodexDailyBucket(
                    sessionID: "cx-1",
                    day: today,
                    inputTokens: 10,
                    outputTokens: 5,
                    reasoningTokens: 2,
                    cacheReadTokens: 1,
                    totalTokens: 18,
                    requestCount: 0
                )
            ]
        )

        let preset = store.derivedData(for: AgentUsageSelection(
            source: .all,
            dateSelection: .preset(.today),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let explicitSingleDay = store.derivedData(for: AgentUsageSelection(
            source: .all,
            dateSelection: .singleDay(today),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let explicitRange = store.derivedData(for: AgentUsageSelection(
            source: .all,
            dateSelection: .dayRange(startDay: today, endDay: today),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertFalse(preset.showsTokenFlow)
        XCTAssertFalse(explicitSingleDay.showsTokenFlow)
        XCTAssertFalse(explicitRange.showsTokenFlow)
        XCTAssertTrue(preset.tokenFlowData.isEmpty)
        XCTAssertTrue(explicitSingleDay.tokenFlowData.isEmpty)
        XCTAssertTrue(explicitRange.tokenFlowData.isEmpty)
    }

    func testAgentUsageSelectionInitializesDateSelectionWithoutLosingExplicitSelection() {
        let selection = AgentUsageSelection(
            source: .openCode,
            dateSelection: .singleDay(19_900),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )

        XCTAssertEqual(selection.dateSelection, .singleDay(19_900))
    }

    func testDerivedDataForSingleDayUsesOnlyBucketsInThatDay() {
        let store = makeStoreWithLoadedState(
            openCodeBuckets: [
                openCodeBucket(day: 100, totalTokens: 50, sessionID: "oc-1"),
                openCodeBucket(day: 101, totalTokens: 75, sessionID: "oc-1")
            ],
            codexBuckets: []
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .singleDay(101),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 75)
    }

    func testDerivedDataForRangeUsesInclusiveEndpoints() {
        let store = makeStoreWithLoadedState(
            openCodeBuckets: [
                openCodeBucket(day: 100, totalTokens: 10, sessionID: "oc-1"),
                openCodeBucket(day: 101, totalTokens: 20, sessionID: "oc-1"),
                openCodeBucket(day: 102, totalTokens: 30, sessionID: "oc-1")
            ],
            codexBuckets: []
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .dayRange(startDay: 100, endDay: 102),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 60)
    }

    func testDateSelectionDoesNotChangeRefreshGeneration() {
        let store = makeStoreWithLoadedState(
            openCodeBuckets: [openCodeBucket(day: 100, totalTokens: 10, sessionID: "oc-1")],
            codexBuckets: []
        )
        let initialGeneration = store.debugRefreshGenerationForTests

        _ = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .singleDay(100),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        _ = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .dayRange(startDay: 100, endDay: 100),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(store.debugRefreshGenerationForTests, initialGeneration)
    }

    func testCodexResolveDatabaseURLPrefersNewestActivityAcrossDuplicateVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let sqliteDir = codexRoot.appendingPathComponent("sqlite")
        let activeRootDB = codexRoot.appendingPathComponent("state_5.sqlite")
        let staleSQLiteDB = sqliteDir.appendingPathComponent("state_5.sqlite")

        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        let rootWriter = try openWritableDatabase(activeRootDB)
        defer { sqlite3_close(rootWriter) }
        let sqliteWriter = try openWritableDatabase(staleSQLiteDB)
        defer { sqlite3_close(sqliteWriter) }

        let schema = """
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
        """
        try execute(rootWriter, sql: schema)
        try execute(sqliteWriter, sql: schema)

        try execute(rootWriter, sql: """
        insert into threads values
        ('root_thread', 'Root', '/tmp/root', 'gpt-5.4', 'openai', 100, '', 'user', null, null, 1000, 2000, 0);
        """)
        try execute(sqliteWriter, sql: """
        insert into threads values
        ('sqlite_thread', 'SQLite', '/tmp/sqlite', 'gpt-5.4', 'openai', 100, '', 'user', null, null, 1000, 1000, 0);
        """)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: staleSQLiteDB.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: activeRootDB.path)

        let chosen = CodexUsageQuery.resolveDatabaseURL(
            environment: [:],
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(
            chosen?.resolvingSymlinksInPath().path,
            activeRootDB.resolvingSymlinksInPath().path
        )
        try? FileManager.default.removeItem(at: activeRootDB.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: activeRootDB.appendingPathExtension("shm"))
        try? FileManager.default.removeItem(at: root)
    }

    func testCodexLoadMergedSnapshotUnionsHistoricalAndActiveDatabases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let sqliteDir = codexRoot.appendingPathComponent("sqlite")
        let activeRootDB = codexRoot.appendingPathComponent("state_5.sqlite")
        let historicalSQLiteDB = sqliteDir.appendingPathComponent("state_5.sqlite")

        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)

        let rootWriter = try openWritableDatabase(activeRootDB)
        defer { sqlite3_close(rootWriter) }
        let sqliteWriter = try openWritableDatabase(historicalSQLiteDB)
        defer { sqlite3_close(sqliteWriter) }

        let schema = """
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
        """
        try execute(rootWriter, sql: schema)
        try execute(sqliteWriter, sql: schema)

        try execute(rootWriter, sql: """
        insert into threads values
        ('shared_thread', 'Shared New', '/tmp/pulse', 'gpt-5.4', 'openai', 500, '', 'user', null, null, 1000, 5000, 0),
        ('active_only', 'Active Only', '/tmp/pulse', 'gpt-5.4', 'openai', 300, '', 'user', null, null, 2000, 6000, 0);
        """)
        try execute(sqliteWriter, sql: """
        insert into threads values
        ('shared_thread', 'Shared Old', '/tmp/pulse', 'gpt-5.4', 'openai', 450, '', 'user', null, null, 1000, 4000, 0),
        ('historical_only', 'Historical Only', '/tmp/old', 'gpt-5.4', 'openai', 200, '', 'user', null, null, 1500, 3000, 0);
        """)

        let snapshot = try CodexUsageQuery.loadMergedSnapshot(
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(snapshot.sessions.map(\.id), ["active_only", "shared_thread", "historical_only"])
        XCTAssertEqual(snapshot.sessions.first(where: { $0.id == "shared_thread" })?.title, "Shared New")
        XCTAssertEqual(snapshot.sessions.first(where: { $0.id == "shared_thread" })?.tokensUsed, 500)
        XCTAssertEqual(snapshot.summary(for: .allProjects).totalTokens, 1_000)

        try? FileManager.default.removeItem(at: root)
    }

    func testCodexLoadMergedSnapshotCanSkipTranscriptURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let sessionDir = codexRoot.appendingPathComponent("sessions/2026/07/01")
        let databaseURL = codexRoot.appendingPathComponent("state_5.sqlite")
        let transcriptURL = sessionDir.appendingPathComponent("thread-1.jsonl")

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

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
        ('thread_1', 'Valid', '/tmp/project', 'gpt-5.4', 'openai', 100, '', 'user', null, null, 1000, 2000, 0);
        """)

        let transcript = """
        {"timestamp":"2026-07-01T10:00:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/tmp/project"}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageQuery.loadMergedSnapshot(
            includeTranscriptURLs: false,
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertNil(snapshot.sessions.first?.transcriptURL)

        try? FileManager.default.removeItem(at: root)
    }

    func testCodexResolveDatabaseURLIgnoresHigherVersionWithoutThreadsTable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let validDB = codexRoot.appendingPathComponent("state_5.sqlite")
        let invalidHigherVersionDB = codexRoot.appendingPathComponent("state_6.sqlite")

        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

        let writer = try openWritableDatabase(validDB)
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
        ('thread_1', 'Valid', '/tmp/project', 'gpt-5.4', 'openai', 100, '', 'user', null, null, 1000, 2000, 0);
        """)

        let invalidWriter = try openWritableDatabase(invalidHigherVersionDB)
        defer { sqlite3_close(invalidWriter) }
        try execute(invalidWriter, sql: "create table metadata_only (id text primary key);")

        let chosen = CodexUsageQuery.resolveDatabaseURL(
            environment: [:],
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(chosen?.resolvingSymlinksInPath().path, validDB.resolvingSymlinksInPath().path)

        try? FileManager.default.removeItem(at: root)
    }

    func testCodexLoadSnapshotReadsRowsPersistedInWALAfterWriterCloses() throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsageQuery-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("shm"))
        }

        let writer = try openWritableDatabase(databaseURL)

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
        sqlite3_close(writer)

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

    func testAgentUsageRepositoryLoadsCodexDetailFromAnyValidStateDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let sqliteDir = codexRoot.appendingPathComponent("sqlite")
        let primaryDB = codexRoot.appendingPathComponent("state_6.sqlite")
        let detailOnlyDB = sqliteDir.appendingPathComponent("state_5.sqlite")

        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)

        let primaryWriter = try openWritableDatabase(primaryDB)
        defer { sqlite3_close(primaryWriter) }
        let detailWriter = try openWritableDatabase(detailOnlyDB)
        defer { sqlite3_close(detailWriter) }

        let threadSchema = """
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
        """
        let edgeSchema = """
        create table thread_spawn_edges (
            parent_thread_id text not null,
            child_thread_id text not null,
            status text
        );
        """
        let goalSchema = """
        create table thread_goals (
            goal_id text,
            thread_id text not null,
            objective text,
            status text,
            token_budget integer,
            tokens_used integer
        );
        """

        try execute(primaryWriter, sql: threadSchema)
        try execute(primaryWriter, sql: edgeSchema)
        try execute(primaryWriter, sql: goalSchema)
        try execute(primaryWriter, sql: """
        insert into threads values
        ('thread_1', 'Primary Metadata', '/tmp/project', 'gpt-5.4', 'openai', 100, '', 'user', null, null, 1000, 5000, 0);
        """)

        try execute(detailWriter, sql: threadSchema)
        try execute(detailWriter, sql: edgeSchema)
        try execute(detailWriter, sql: goalSchema)
        try execute(detailWriter, sql: """
        insert into threads values
        ('thread_1', 'Historical Metadata', '/tmp/project', 'gpt-5.4', 'openai', 80, '', 'user', null, null, 1000, 4000, 0);
        insert into thread_spawn_edges values ('thread_1', 'child_1', 'complete');
        insert into thread_goals values ('goal_1', 'thread_1', 'Ship it', 'active', 5000, 1234);
        """)

        let repository = AgentUsageRepository(
            openCodeDatabaseURL: URL(fileURLWithPath: "/tmp/opencode.db"),
            codexDatabaseURL: primaryDB
        )

        let detail = try repository.loadCodexDetail(
            threadID: "thread_1",
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(detail.threadID, "thread_1")
        XCTAssertEqual(detail.edges.count, 1)
        XCTAssertEqual(detail.edges.first?.childThreadID, "child_1")
        XCTAssertEqual(detail.goals.count, 1)
        XCTAssertEqual(detail.goals.first?.objective, "Ship it")

        try? FileManager.default.removeItem(at: root)
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

    func testDerivedDataAllSourceCountsOnlyEnabledSources() {
        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1", tokens: 100)])
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 200)])

        let store = AgentUsageStore(repository: repository)
        store.setEnabledSources([.codex])
        store.refreshAll()

        let data = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 200)
        XCTAssertEqual(store.availableSources, [.codex])
    }

    func testDerivedDataAllSourceShowsProviderAndModelBreakdownsPerSourceWhenUnmapped() {
        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            makeOpenCodeSession(id: "oc_1", tokens: 100, providerID: "custom", modelID: "gpt-5.4")
        ])
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(id: "cx_1", tokens: 200, provider: "codex-gpt", model: "gpt-5.4")
        ])

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let data = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertTrue(data.showsByModel)
        XCTAssertEqual(Set(data.providerBreakdown.map(\.provider)), ["OpenCode / custom", "Codex / codex-gpt"])
        XCTAssertEqual(Set(data.modelBreakdownRows.map(\.title)), ["OpenCode / custom / gpt-5.4", "Codex / codex-gpt / gpt-5.4"])
    }

    func testDerivedDataAllSourceAppliesMappingsWithoutChangingPerAgentBreakdowns() {
        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            makeOpenCodeSession(id: "oc_1", tokens: 100, providerID: "custom", modelID: "gpt-5.4")
        ])
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(id: "cx_1", tokens: 200, provider: "codex-gpt", model: "gpt-5.4")
        ])

        let mappingStore = AgentUsageMappingStore(
            persistence: InMemoryAgentUsageMappingPersistence()
        )
        mappingStore.upsertProviderMapping(
            AgentUsageProviderDisplayMapping(
                identity: AgentUsageProviderRawIdentity(
                    source: .openCode,
                    rawProviderID: "custom",
                    rawProviderName: "custom"
                ),
                displayProviderName: "OpenAI"
            )
        )
        mappingStore.upsertProviderMapping(
            AgentUsageProviderDisplayMapping(
                identity: AgentUsageProviderRawIdentity(
                    source: .codex,
                    rawProviderID: "codex-gpt",
                    rawProviderName: "codex-gpt"
                ),
                displayProviderName: "OpenAI"
            )
        )
        mappingStore.upsertModelMapping(
            AgentUsageModelDisplayMapping(
                identity: AgentUsageModelRawIdentity(
                    source: .openCode,
                    rawProviderID: "custom",
                    rawProviderName: "custom",
                    rawModelID: "gpt-5.4",
                    rawModelName: "gpt-5.4",
                    rawModelVariant: nil
                ),
                displayProviderName: "OpenAI",
                displayModelName: "gpt-5.4"
            )
        )
        mappingStore.upsertModelMapping(
            AgentUsageModelDisplayMapping(
                identity: AgentUsageModelRawIdentity(
                    source: .codex,
                    rawProviderID: "codex-gpt",
                    rawProviderName: "codex-gpt",
                    rawModelID: "gpt-5.4",
                    rawModelName: "gpt-5.4",
                    rawModelVariant: nil
                ),
                displayProviderName: "OpenAI",
                displayModelName: "gpt-5.4"
            )
        )

        let store = AgentUsageStore(repository: repository, mappingStore: mappingStore)
        store.refreshAll()

        let allData = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let openCodeData = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let codexData = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(allData.providerBreakdown.map(\.provider), ["OpenAI"])
        XCTAssertEqual(allData.modelBreakdownRows.map(\.title), ["OpenAI / gpt-5.4"])
        XCTAssertEqual(openCodeData.providerBreakdown.map(\.provider), ["custom"])
        XCTAssertEqual(openCodeData.modelBreakdownRows.map(\.title), ["custom / gpt-5.4"])
        XCTAssertEqual(codexData.providerBreakdown.map(\.provider), ["codex-gpt"])
        XCTAssertEqual(codexData.modelBreakdownRows.map(\.title), ["codex-gpt / gpt-5.4"])
    }

    func testRefreshAllSkipsDeselectedSources() {
        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1", tokens: 100)])
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 200)])

        let store = AgentUsageStore(repository: repository)
        store.setEnabledSources([.codex])
        store.refreshAll()

        XCTAssertEqual(repository.openCodeLoadCount, 0)
        XCTAssertEqual(repository.openCodeBucketLoadCount, 0)
        XCTAssertEqual(repository.codexLoadCount, 1)
        XCTAssertEqual(repository.codexBucketLoadCount, 1)
        XCTAssertTrue(store.state.openCodeCumulativeSnapshot.sessions.isEmpty)
        XCTAssertTrue(store.state.openCodeDailyBuckets.isEmpty)
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
            cacheReadTokens: 1000, cacheWriteTokens: 4, requestCount: 0, cost: 0.02)]
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
                cacheReadTokens: 500, cacheWriteTokens: 2, requestCount: 0, cost: 0.01)
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        XCTAssertEqual(repository.openCodeLoadCount, 1)
        XCTAssertEqual(repository.openCodeBucketLoadCount, 1)
        XCTAssertEqual(store.state.openCodeDailyBuckets.count, 1)
        XCTAssertEqual(store.state.openCodeCumulativeSnapshot.sessions.count, 1)
    }

    func testDerivedDataUsesBucketsForTodayAndCumulativeForAllTime() {
        let todayDay = agentUsageDayIdentifier(for: Date())

        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            makeOpenCodeSession(id: "ses_1", tokens: 1000)
        ])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(sessionID: "ses_1", day: todayDay,
                inputTokens: 10, outputTokens: 5, reasoningTokens: 1,
                cacheReadTokens: 20, cacheWriteTokens: 2, requestCount: 0, cost: 0.001)
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

    func testOpenCodeRangedLastUpdatedUsesLatestInRangeActivityDay() {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let todayDay = agentUsageDayIdentifier(for: today, calendar: calendar)
        let futureUpdatedAt = calendar.date(byAdding: .day, value: 3, to: now) ?? now

        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            OpenCodeSessionRecord(
                id: "ses_1",
                title: "Session ses_1",
                directory: "/Users/zyao/Desktop/pulse",
                agent: "build",
                modelProviderID: "opencode",
                modelID: "model-a",
                modelVariant: nil,
                inputTokens: 1000,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 0,
                cost: 0,
                createdAt: now.addingTimeInterval(-3600),
                updatedAt: futureUpdatedAt
            )
        ])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(
                sessionID: "ses_1",
                day: todayDay,
                inputTokens: 10,
                outputTokens: 5,
                reasoningTokens: 1,
                cacheReadTokens: 20,
                cacheWriteTokens: 2,
                requestCount: 0,
                cost: 0.001
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let selection = AgentUsageSelection(
            source: .openCode,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )
        let data = store.derivedData(for: selection)

        XCTAssertEqual(data.summary.totalTokens, 38)
        XCTAssertEqual(
            data.summary.lastUpdated.map { agentUsageDayIdentifier(for: $0, calendar: calendar) },
            todayDay
        )
    }

    func testOpenCodeAllTimeUsesActivityTimestampForSummarySessionOptionAndSessionContext() {
        let oldMetadataTime = Date(timeIntervalSince1970: 1_000)
        let latestActivityTime = Date(timeIntervalSince1970: 5_000)
        let activityDay = agentUsageDayIdentifier(for: latestActivityTime)

        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            OpenCodeSessionRecord(
                id: "ses_1",
                title: "Session ses_1",
                directory: "/Users/zyao/Desktop/pulse",
                agent: "build",
                modelProviderID: "opencode",
                modelID: "model-a",
                modelVariant: nil,
                inputTokens: 1000,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 0,
                cost: 0,
                createdAt: oldMetadataTime,
                updatedAt: oldMetadataTime
            )
        ])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(
                sessionID: "ses_1",
                day: activityDay,
                inputTokens: 10,
                outputTokens: 5,
                reasoningTokens: 1,
                cacheReadTokens: 20,
                cacheWriteTokens: 2,
                requestCount: 0,
                cost: 0.001,
                latestActivityAt: latestActivityTime
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let projectSelection = AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: nil,
            modelGroupBy: .model
        )
        let projectData = store.derivedData(for: projectSelection)

        XCTAssertEqual(projectData.summary.lastUpdated, latestActivityTime)
        XCTAssertEqual(projectData.sessionOptions.count, 1)
        XCTAssertTrue(projectData.sessionOptions[0].subtitle.contains(formatAgentUsageDate(latestActivityTime)))

        let sessionSelection = AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: "ses_1",
            modelGroupBy: .model
        )
        let sessionData = store.derivedData(for: sessionSelection)
        XCTAssertEqual(sessionData.summary.lastUpdated, latestActivityTime)
        XCTAssertEqual(
            sessionData.contextRows.first(where: { $0.id == "lastUpdated" })?.valueText,
            formatAgentUsageDate(latestActivityTime)
        )
    }

    func testOpenCodeAllProjectsAllTimeUsesActivityTimestampForSummaryAndContext() {
        let oldMetadataTime = Date(timeIntervalSince1970: 1_000)
        let latestActivityTime = Date(timeIntervalSince1970: 5_000)
        let activityDay = agentUsageDayIdentifier(for: latestActivityTime)

        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            OpenCodeSessionRecord(
                id: "ses_1",
                title: "Session ses_1",
                directory: "/Users/zyao/Desktop/pulse",
                agent: "build",
                modelProviderID: "opencode",
                modelID: "model-a",
                modelVariant: nil,
                inputTokens: 1000,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 0,
                cost: 0,
                createdAt: oldMetadataTime,
                updatedAt: oldMetadataTime
            )
        ])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(
                sessionID: "ses_1",
                day: activityDay,
                inputTokens: 10,
                outputTokens: 5,
                reasoningTokens: 1,
                cacheReadTokens: 20,
                cacheWriteTokens: 2,
                requestCount: 0,
                cost: 0.001,
                latestActivityAt: latestActivityTime
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let selection = AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )
        let data = store.derivedData(for: selection)

        XCTAssertEqual(data.summary.lastUpdated, latestActivityTime)
        XCTAssertEqual(
            data.contextRows.first(where: { $0.id == "lastUpdated" })?.valueText,
            formatAgentUsageDate(latestActivityTime)
        )
    }

    func testCodexAllTimeUsesActivityTimestampForSummarySessionOptionAndSessionContext() {
        let oldMetadataTime = Date(timeIntervalSince1970: 2_000)
        let latestActivityTime = Date(timeIntervalSince1970: 7_000)
        let activityDay = agentUsageDayIdentifier(for: latestActivityTime)

        let repository = StubAgentUsageRepository()
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(id: "cx_1", tokens: 999, updatedAt: oldMetadataTime)
        ])
        repository.codexDailyBuckets = [
            CodexDailyBucket(
                sessionID: "cx_1",
                day: activityDay,
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 40,
                totalTokens: 120,
                requestCount: 0,
                latestActivityAt: latestActivityTime
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let projectSelection = AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: nil,
            modelGroupBy: .model
        )
        let projectData = store.derivedData(for: projectSelection)

        XCTAssertEqual(projectData.summary.lastUpdated, latestActivityTime)
        XCTAssertEqual(projectData.sessionOptions.count, 1)
        XCTAssertTrue(projectData.sessionOptions[0].subtitle.contains(formatAgentUsageDate(latestActivityTime)))

        let sessionSelection = AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: "cx_1",
            modelGroupBy: .model
        )
        let sessionData = store.derivedData(for: sessionSelection)
        XCTAssertEqual(sessionData.summary.lastUpdated, latestActivityTime)
        XCTAssertEqual(
            sessionData.contextRows.first(where: { $0.id == "lastUpdated" })?.valueText,
            formatAgentUsageDate(latestActivityTime)
        )
    }

    func testCodexAllProjectsAllTimeUsesActivityTimestampForSummaryAndContext() {
        let oldMetadataTime = Date(timeIntervalSince1970: 2_000)
        let latestActivityTime = Date(timeIntervalSince1970: 7_000)
        let activityDay = agentUsageDayIdentifier(for: latestActivityTime)

        let repository = StubAgentUsageRepository()
        repository.codexSnapshot = CodexUsageSnapshot(sessions: [
            makeCodexSession(id: "cx_1", tokens: 999, updatedAt: oldMetadataTime)
        ])
        repository.codexDailyBuckets = [
            CodexDailyBucket(
                sessionID: "cx_1",
                day: activityDay,
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 40,
                totalTokens: 120,
                requestCount: 0,
                latestActivityAt: latestActivityTime
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let selection = AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        )
        let data = store.derivedData(for: selection)

        XCTAssertEqual(data.summary.lastUpdated, latestActivityTime)
        XCTAssertEqual(
            data.contextRows.first(where: { $0.id == "lastUpdated" })?.valueText,
            formatAgentUsageDate(latestActivityTime)
        )
    }

    func testDerivedDataUsesBucketsForLast7DaysIncludingToday() {
        let todayDay = agentUsageDayIdentifier(for: Date())

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
                totalTokens: 120,
                requestCount: 0
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
        let todayDay = agentUsageDayIdentifier(for: Date())

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
                totalTokens: 90,
                requestCount: 0
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

    func testOpenCodeRangedModelBreakdownUsesBucketModelMetadata() {
        let todayDay = agentUsageDayIdentifier(for: Date())

        let repository = StubAgentUsageRepository()
        repository.openCodeCumulativeSnapshot = OpenCodeUsageSnapshot(sessions: [
            OpenCodeSessionRecord(
                id: "ses_1",
                title: "Session ses_1",
                directory: "/Users/zyao/Desktop/pulse",
                agent: "build",
                modelProviderID: "stepfun",
                modelID: "step-3.7-flash",
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
        ])
        repository.openCodeDailyBuckets = [
            OpenCodeDailyBucket(
                sessionID: "ses_1",
                day: todayDay,
                modelProviderID: "codex-gpt",
                modelID: "gpt-5.4",
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 40,
                cacheWriteTokens: 0,
                requestCount: 0,
                cost: 0
            )
        ]

        let store = AgentUsageStore(repository: repository)
        store.refreshAll()

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.modelBreakdownRows.count, 1)
        XCTAssertEqual(data.modelBreakdownRows[0].title, "codex-gpt / gpt-5.4")
        XCTAssertEqual(data.modelBreakdownRows[0].valueText, "165")
    }

    func testCodexLoadDailyBucketsSplitsCrossDaySessionFromTranscript() throws {
        try withTimeZone("UTC") {
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
                        totalTokens: 120,
                        requestCount: 1,
                        latestActivityAt: ISO8601DateFormatter().date(from: "2026-06-16T23:55:00Z")
                    ),
                    CodexDailyBucket(
                        sessionID: "thread_1",
                        day: 20621,
                        inputTokens: 90,
                        outputTokens: 10,
                        reasoningTokens: 3,
                        cacheReadTokens: 40,
                        totalTokens: 100,
                        requestCount: 1,
                        latestActivityAt: ISO8601DateFormatter().date(from: "2026-06-17T00:05:00Z")
                    )
                ]
            )

            try? FileManager.default.removeItem(at: root)
        }
    }

    func testCodexLoadDailyBucketsUsesLocalCalendarDay() throws {
        try withTimeZone("America/Los_Angeles") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let home = root.appendingPathComponent("home")
            let sessionDir = home.appendingPathComponent(".codex/sessions/2026/06/17")
            let transcriptURL = sessionDir.appendingPathComponent("local-day-test.jsonl")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            let transcript = """
            {"timestamp":"2026-06-17T23:50:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/Users/zyao/Desktop/pulse"}}
            {"timestamp":"2026-06-17T23:55:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
            {"timestamp":"2026-06-18T00:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":190,"cached_input_tokens":80,"output_tokens":30,"reasoning_output_tokens":8,"total_tokens":220}}}}
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
                        day: 20621,
                        inputTokens: 190,
                        outputTokens: 30,
                        reasoningTokens: 8,
                        cacheReadTokens: 80,
                        totalTokens: 220,
                        requestCount: 2,
                        latestActivityAt: ISO8601DateFormatter().date(from: "2026-06-18T00:05:00Z")
                    )
                ]
            )

            try? FileManager.default.removeItem(at: root)
        }
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

    func testCodexLoadDailyBucketsIgnoresNonUsageTranscriptLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let sessionDir = home.appendingPathComponent(".codex/sessions/2026/06/16")
        let transcriptURL = sessionDir.appendingPathComponent("non-usage-lines-test.jsonl")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let transcript = """
        {"timestamp":"2026-06-16T23:55:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/Users/zyao/Desktop/pulse"}}
        {"timestamp":"2026-06-16T23:55:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"token_count should not matter in user text only when quoted differently"}]}}
        {"timestamp":"2026-06-16T23:55:02Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"2026-06-16T23:56:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let buckets = try CodexUsageQuery.loadDailyBuckets(
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].sessionID, "thread_1")
        XCTAssertEqual(buckets[0].totalTokens, 120)

        try? FileManager.default.removeItem(at: root)
    }

    func testDerivedDataUsesCodexBucketsForTodayInsteadOfSessionUpdatedAt() {
        let todayDay = agentUsageDayIdentifier(for: Date())

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
                totalTokens: 500,
                requestCount: 0
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
        let todayDay = agentUsageDayIdentifier(for: Date())

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
                totalTokens: 120,
                requestCount: 0
            ),
            CodexDailyBucket(
                sessionID: "cx_1",
                day: todayDay,
                inputTokens: 90,
                outputTokens: 10,
                reasoningTokens: 3,
                cacheReadTokens: 40,
                totalTokens: 100,
                requestCount: 0
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

    func testAgentUsageDayRangeMatchesLocalCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let formatter = ISO8601DateFormatter()
        let sameLocalDay = formatter.date(from: "2026-06-18T00:05:00Z")!
        let nextLocalDay = formatter.date(from: "2026-06-18T08:05:00Z")!

        let expectedStartOfDay = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 17,
            hour: 0,
            minute: 0
        ))!

        let todayDay = agentUsageDayIdentifier(for: sameLocalDay, calendar: calendar)
        let nextDay = agentUsageDayIdentifier(for: nextLocalDay, calendar: calendar)
        let todayRange = agentUsageDayRange(for: .today, now: sameLocalDay, calendar: calendar)

        XCTAssertEqual(todayDay, Int(expectedStartOfDay.timeIntervalSince1970 * 1000) / 86_400_000)
        XCTAssertTrue(todayRange.contains(todayDay))
        XCTAssertFalse(todayRange.contains(nextDay))
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

private func makeStoreWithLoadedState(
    openCodeBuckets: [OpenCodeDailyBucket],
    codexBuckets: [CodexDailyBucket]
) -> AgentUsageStore {
    let store = AgentUsageStore(repository: StubAgentUsageRepository())
    let openCodeSessions = Set(openCodeBuckets.map(\.sessionID)).map { sessionID in
        makeOpenCodeSession(id: sessionID, tokens: 999)
    }
    let codexSessions = Set(codexBuckets.map(\.sessionID)).map { sessionID in
        makeCodexSession(id: sessionID, tokens: 999)
    }
    store.replaceStateForTesting(
        AgentUsageLoadedState(
            openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: openCodeSessions),
            openCodeDailyBuckets: openCodeBuckets,
            codexSnapshot: CodexUsageSnapshot(sessions: codexSessions),
            codexDailyBuckets: codexBuckets,
            refreshGeneration: 1,
            codexDetailCache: [:]
        )
    )
    return store
}

private func openCodeBucket(day: Int, totalTokens: Int, sessionID: String) -> OpenCodeDailyBucket {
    OpenCodeDailyBucket(
        sessionID: sessionID,
        day: day,
        modelProviderID: "opencode",
        modelID: "model-a",
        modelVariant: nil,
        inputTokens: totalTokens,
        outputTokens: 0,
        reasoningTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        requestCount: 0,
        cost: 0,
        latestActivityAt: nil
    )
}

private func makeOpenCodeSession(
    id: String,
    tokens: Int = 100,
    providerID: String = "opencode",
    modelID: String = "model-a",
    modelVariant: String? = nil
) -> OpenCodeSessionRecord {
    OpenCodeSessionRecord(
        id: id,
        title: "Session \(id)",
        directory: "/Users/zyao/Desktop/pulse",
        agent: "build",
        modelProviderID: providerID,
        modelID: modelID,
        modelVariant: modelVariant,
        inputTokens: tokens,
        outputTokens: 0,
        reasoningTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        requestCount: 0,
        cost: 0,
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: Date(timeIntervalSince1970: 2000)
    )
}

private func makeCodexSession(id: String, tokens: Int = 100) -> CodexSessionRecord {
    makeCodexSession(id: id, tokens: tokens, provider: "openai", model: "gpt-5", updatedAt: Date(timeIntervalSince1970: 2000))
}

private func makeCodexSession(
    id: String,
    tokens: Int = 100,
    provider: String = "openai",
    model: String = "gpt-5",
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
        model: model,
        modelProvider: provider,
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

private func formatAgentUsageDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
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

    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail {
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

    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail {
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

private func withTimeZone(_ identifier: String, perform work: () throws -> Void) throws {
    let previous = ProcessInfo.processInfo.environment["TZ"]
    setenv("TZ", identifier, 1)
    tzset()
    NSTimeZone.resetSystemTimeZone()
    defer {
        if let previous {
            setenv("TZ", previous, 1)
        } else {
            unsetenv("TZ")
        }
        tzset()
        NSTimeZone.resetSystemTimeZone()
    }

    try work()
}

private extension Calendar {
    static var gregorianUTCForTests: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
