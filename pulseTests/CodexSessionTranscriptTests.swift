import XCTest
import SQLite3
@testable import Pulse

final class CodexSessionTranscriptTests: XCTestCase {
    func testCodexTranscriptLoaderReturnsUserAndAssistantTurnsInOrder() throws {
        let transcript = try loadCodexTranscriptFixture()

        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.text), ["Investigate the crash", "I found the nil path in AppDelegate."])
    }

    func testCodexTranscriptLoaderChoosesMostCompleteMatchingTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let sessionsDir = home.appendingPathComponent(".codex/sessions/2026/06/29")
        let archivedDir = home.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lessCompleteURL = sessionsDir.appendingPathComponent("thread-1-live.jsonl")
        let moreCompleteURL = archivedDir.appendingPathComponent("thread-1-archived.jsonl")

        let lessComplete = """
        {"timestamp":"2026-06-29T10:00:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/tmp/project"}}
        {"timestamp":"2026-06-29T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Investigate the crash"}]}}
        """

        let moreComplete = """
        {"timestamp":"2026-06-29T10:00:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/tmp/project"}}
        {"timestamp":"2026-06-29T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Investigate the crash"}]}}
        {"timestamp":"2026-06-29T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I found the nil path in AppDelegate."}]}}
        """

        try lessComplete.write(to: lessCompleteURL, atomically: true, encoding: .utf8)
        try moreComplete.write(to: moreCompleteURL, atomically: true, encoding: .utf8)

        let transcript = try CodexUsageQuery.loadTranscript(
            threadID: "thread_1",
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(transcript.map(\.text), ["Investigate the crash", "I found the nil path in AppDelegate."])
    }

    func testCodexResumeActionUsesSourceNativeCommand() {
        let action = SessionManagementRepository().resumeAction(
            for: ManagedSessionSummary(
                id: "codex::thread_1",
                source: .codex,
                rawSessionID: "thread_1",
                title: "Transcript",
                projectPath: "/tmp/project",
                projectName: "project",
                subtitle: "openai / gpt-5.4",
                updatedAt: Date(timeIntervalSince1970: 2_000),
                transcriptURL: nil
            )
        )

        XCTAssertEqual(action, .codex(command: "codex resume thread_1"))
    }

    func testLoadMergedSnapshotAnnotatesSessionWithTranscriptURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let sqliteDir = home.appendingPathComponent(".codex/sqlite")
        let sessionDir = home.appendingPathComponent(".codex/sessions/2026/06/29")
        let databaseURL = sqliteDir.appendingPathComponent("state_1.sqlite")
        let transcriptURL = sessionDir.appendingPathComponent("thread-1.jsonl")
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try openCodexWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }
        try executeCodexSQL(db, sql: """
        create table threads (
            id text primary key,
            title text,
            cwd text,
            model text,
            model_provider text,
            tokens_used integer,
            reasoning_effort text,
            thread_source text,
            agent_nickname text,
            agent_role text,
            created_at_ms integer,
            updated_at_ms integer
        );
        """)
        try executeCodexSQL(db, sql: """
        insert into threads (
            id, title, cwd, model, model_provider, tokens_used,
            reasoning_effort, thread_source, agent_nickname, agent_role,
            created_at_ms, updated_at_ms
        ) values (
            'thread_1', 'Transcript', '/tmp/project', 'gpt-5.4', 'openai', 120,
            '', 'user', null, null, 1000, 2000
        );
        """)

        let transcript = """
        {"timestamp":"2026-06-29T10:00:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/tmp/project"}}
        {"timestamp":"2026-06-29T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Investigate the crash"}]}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageQuery.loadMergedSnapshot(
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(
            snapshot.sessions.first?.transcriptURL?.standardizedFileURL,
            transcriptURL.standardizedFileURL
        )
    }

    func testRepositoryUsesCachedCodexTranscriptURLWhenAvailable() throws {
        let expectedTranscriptURL = URL(fileURLWithPath: "/tmp/thread-1.jsonl")
        var capturedThreadID: String?
        var capturedTranscriptURL: URL?

        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/missing-opencode.sqlite") },
            loadOpenCodeSnapshot: { _ in
                throw OpenCodeUsageQuery.QueryError.databaseNotFound(path: "/tmp/missing-opencode.sqlite")
            },
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
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        transcriptURL: expectedTranscriptURL
                    )
                ])
            },
            loadCodexTranscriptProgressively: { threadID, transcriptURL, _ in
                capturedThreadID = threadID
                capturedTranscriptURL = transcriptURL
                return [TranscriptTurn(id: "t1", role: .assistant, text: "Done", timestamp: nil)]
            }
        )

        let sessions = try repository.loadManagedSessions()
        XCTAssertEqual(sessions.map(\.id), ["codex::thread_1"])
        XCTAssertEqual(sessions.first?.transcriptURL, expectedTranscriptURL)
        _ = try repository.loadTranscript(for: sessions[0])

        XCTAssertEqual(capturedThreadID, "thread_1")
        XCTAssertEqual(capturedTranscriptURL, expectedTranscriptURL)
    }

    func testRepositoryManagedSessionsRetainCodexTranscriptURL() throws {
        let expectedTranscriptURL = URL(fileURLWithPath: "/tmp/thread-1.jsonl")

        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/missing-opencode.sqlite") },
            loadOpenCodeSnapshot: { _ in
                throw OpenCodeUsageQuery.QueryError.databaseNotFound(path: "/tmp/missing-opencode.sqlite")
            },
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
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        transcriptURL: expectedTranscriptURL
                    )
                ])
            },
            loadCodexTranscriptProgressively: { _, _, _ in [] }
        )

        let sessions = try repository.loadManagedSessions()

        XCTAssertEqual(sessions.map(\.id), ["codex::thread_1"])
        XCTAssertEqual(sessions.first?.transcriptURL, expectedTranscriptURL)
    }

    func testRepositoryLoadManagedSessionsReturnsNewestUpdatedAtFirstAcrossSources() throws {
        let openCodeSession = OpenCodeSessionRecord(
            id: "oc_1",
            title: "Older OpenCode Session",
            directory: "/tmp/project-a",
            agent: "build",
            modelProviderID: "anthropic",
            modelID: "sonnet",
            modelVariant: nil,
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            requestCount: 0,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let codexSession = CodexSessionRecord(
            id: "thread_2",
            title: "Newer Codex Session",
            cwd: "/tmp/project-b",
            model: "gpt-5.4",
            modelProvider: "openai",
            tokensUsed: 0,
            inputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            cacheReadTokens: nil,
            reasoningEffort: "",
            threadSource: "user",
            agentNickname: nil,
            agentRole: nil,
            createdAt: Date(timeIntervalSince1970: 1_500),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            transcriptURL: nil
        )

        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/opencode.sqlite") },
            loadOpenCodeSnapshot: { _ in
                OpenCodeUsageSnapshot(sessions: [openCodeSession])
            },
            loadCodexSnapshot: {
                CodexUsageSnapshot(sessions: [codexSession])
            },
            loadCodexTranscriptProgressively: { _, _, _ in [] }
        )

        let sessions = try repository.loadManagedSessions()

        XCTAssertEqual(sessions.map(\.id), ["codex::thread_2", "opencode::oc_1"])
        XCTAssertEqual(sessions.map(\.updatedAt), [
            Date(timeIntervalSince1970: 2_000),
            Date(timeIntervalSince1970: 1_000)
        ])
    }

    private func loadCodexTranscriptFixture() throws -> [TranscriptTurn] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let sessionDir = home.appendingPathComponent(".codex/sessions/2026/06/29")
        let transcriptURL = sessionDir.appendingPathComponent("thread-1.jsonl")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = """
        {"timestamp":"2026-06-29T10:00:00Z","type":"session_meta","payload":{"id":"thread_1","cwd":"/tmp/project"}}
        {"timestamp":"2026-06-29T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Investigate the crash"}]}}
        {"timestamp":"2026-06-29T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I found the nil path in AppDelegate."}]}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        return try CodexUsageQuery.loadTranscript(
            threadID: "thread_1",
            homeDirectoryURL: home,
            fileManager: .default
        )
    }
}

private func openCodexWritableDatabase(_ url: URL) throws -> OpaquePointer? {
    var db: OpaquePointer?
    if sqlite3_open(url.path, &db) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw NSError(domain: "CodexSessionTranscriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return db
}

private func executeCodexSQL(_ db: OpaquePointer?, sql: String) throws {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        throw NSError(domain: "CodexSessionTranscriptTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
