import XCTest
@testable import Pulse

final class ClaudeCodeTranscriptTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var projectsDir: URL!
    private var indexDatabaseURL: URL { root.appendingPathComponent("Pulse/agent-usage-index.sqlite") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home")
        projectsDir = home.appendingPathComponent(".claude/projects/-Users-tmp-project")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTranscript(_ contents: String, id: String) throws {
        try contents.write(to: projectsDir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    func testLoadSnapshotBuildsSessionRecord() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_1"}
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_1"}
        {"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_1"}
        {"type":"ai-title","aiTitle":"Fix the crash","sessionId":"ses_1"}
        {"type":"last-prompt","lastPrompt":"fix the crash","leafUuid":"a1","sessionId":"ses_1"}
        """, id: "ses_1")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)

        XCTAssertEqual(snapshot.sessions.count, 1)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.id, "ses_1")
        XCTAssertEqual(session.cwd, "/tmp/project")
        XCTAssertEqual(session.model, "claude-sonnet-4")
        XCTAssertEqual(session.modelProvider, "Claude")
        XCTAssertEqual(session.title, "Fix the crash")
        XCTAssertEqual(session.tokensUsed, 135)
        XCTAssertEqual(session.inputTokens, 100)
        XCTAssertEqual(session.outputTokens, 20)
        XCTAssertEqual(session.cacheReadTokens, 10)
        XCTAssertEqual(session.cacheWriteTokens, 5)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:00Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:05Z")!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLoadSnapshotFallsBackToLastPromptTitle() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":1,"output_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_2"}
        {"type":"last-prompt","lastPrompt":"do the thing","leafUuid":"a1","sessionId":"ses_2"}
        """, id: "ses_2")

        let initialSnapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        XCTAssertEqual(initialSnapshot.sessions.first?.title, "do the thing")

        let cachedSnapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        XCTAssertEqual(cachedSnapshot.sessions.first?.title, "do the thing")

        let store = try AgentUsageIndexStore(databaseURL: indexDatabaseURL)
        let records = try store.records(source: "claude:\(home.standardizedFileURL.path)")
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.values.first)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        let accumulator = try XCTUnwrap(payload["accumulator"] as? [String: Any])
        XCTAssertNil(accumulator["lastPrompt"])
    }

    func testLoadDailyBucketsAggregatesAcrossDaysAndSessions() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_3"}
        {"type":"assistant","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":20,"output_tokens":4,"cache_read_input_tokens":6,"cache_creation_input_tokens":2}},"uuid":"a2","timestamp":"2026-07-22T10:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_3"}
        {"type":"assistant","message":{"id":"m3","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":5,"output_tokens":1}},"uuid":"a3","timestamp":"2026-07-23T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_4"}
        """, id: "ses_3")

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)

        XCTAssertEqual(buckets.count, 2)
        let day = agentUsageDayIdentifier(for: ISO8601DateFormatter().date(from: "2026-07-22T00:00:00Z")!)
        let aggregated = try XCTUnwrap(buckets.first { $0.sessionID == "ses_3" && $0.day == day })
        XCTAssertEqual(aggregated.requestCount, 2)
        XCTAssertEqual(aggregated.inputTokens, 30)
        XCTAssertEqual(aggregated.outputTokens, 6)
        XCTAssertEqual(aggregated.cacheReadTokens, 9)
        XCTAssertEqual(aggregated.cacheWriteTokens, 3)
        XCTAssertEqual(aggregated.totalTokens, 48)
        let second = try XCTUnwrap(buckets.first { $0.sessionID == "ses_4" })
        XCTAssertEqual(second.requestCount, 1)
        XCTAssertEqual(second.totalTokens, 6)
    }

    func testLoadDailyBucketsIgnoresMalformedTail() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_5"}
        {"type":"assistant","message":{"id": "m2", "truncated
        """, id: "ses_5")

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.requestCount, 1)
    }

    func testLoadSnapshotIncludesZeroTokenUserOnlySession() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_6"}
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"never answered"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_6"}
        {"type":"last-prompt","lastPrompt":"never answered","leafUuid":"u1","sessionId":"ses_6"}
        """, id: "ses_6")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.id, "ses_6")
        XCTAssertEqual(session.tokensUsed, 0)
        XCTAssertEqual(session.title, "never answered")
    }

    func testLoadSnapshotIgnoresPhantomFilesWithNoConversation() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_7"}
        {"type":"permission-mode","permissionMode":"default","sessionId":"ses_7"}
        """, id: "ses_7")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testLoadSnapshotCreatedAtIsSessionStartNotFirstAssistantMessage() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_8"}
        {"type":"user","message":{"role":"user","content":"typed first"},"uuid":"u1","timestamp":"2026-07-22T08:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_8"}
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":1,"output_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_8"}
        """, id: "ses_8")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T08:00:00Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:05Z")!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSecondLoadReusesCacheWhenTranscriptsUnchanged() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_9"}
        """, id: "ses_9")

        _ = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        _ = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        XCTAssertEqual(snapshot.sessions.map(\.id), ["ses_9"])
    }

    func testAppendedUsageCommitsOnlyCompleteLinesToTheSharedIndex() throws {
        let indexDatabaseURL = root.appendingPathComponent("Pulse/agent-usage-index.sqlite")
        let transcriptURL = projectsDir.appendingPathComponent("ses_incremental.jsonl")
        let firstLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":10,"output_tokens":0}},"timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_incremental"}"#
        let secondLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":20,"output_tokens":0}},"timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_incremental"}"#
        let thirdLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":30,"output_tokens":0}},"timestamp":"2026-07-22T09:02:05.000Z","cwd":"/tmp/project","sessionId":"ses_incremental"}"#
        let incompleteThirdLine = String(thirdLine.dropLast(12))
        let thirdLineRemainder = String(thirdLine.suffix(12))
        try (firstLine + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let initial = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertEqual(initial.dailyBuckets.first?.inputTokens, 10)

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((secondLine + "\n" + incompleteThirdLine).utf8))
        try handle.close()

        let withIncompleteTail = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertEqual(withIncompleteTail.dailyBuckets.first?.inputTokens, 30)
        XCTAssertEqual(withIncompleteTail.dailyBuckets.first?.requestCount, 2)

        let appendHandle = try FileHandle(forWritingTo: transcriptURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data((thirdLineRemainder + "\n").utf8))
        try appendHandle.close()

        let completed = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertEqual(completed.dailyBuckets.first?.inputTokens, 60)
        XCTAssertEqual(completed.dailyBuckets.first?.requestCount, 3)
    }

    func testReplacingAndRemovingTranscriptReplacesItsIndexedContribution() throws {
        try writeTranscript(#"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":10,"output_tokens":0}},"timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_replaced"}"#, id: "ses_replaced")
        let initial = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertEqual(initial.dailyBuckets.first?.inputTokens, 10)

        try writeTranscript(#"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":3,"output_tokens":0}},"timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_replaced"}"#, id: "ses_replaced")
        let replaced = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertEqual(replaced.dailyBuckets.first?.inputTokens, 3)
        XCTAssertEqual(replaced.dailyBuckets.first?.requestCount, 1)

        try FileManager.default.removeItem(at: projectsDir.appendingPathComponent("ses_replaced.jsonl"))
        let removed = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertTrue(removed.snapshot.sessions.isEmpty)
        XCTAssertTrue(removed.dailyBuckets.isEmpty)
    }

    func testTimezoneChangeRebucketsCachedTranscriptUsage() throws {
        let timestamp = "2026-07-22T01:00:00Z"
        let usageDate = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
        try writeTranscript(#"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":10,"output_tokens":0}},"timestamp":"2026-07-22T01:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_timezone"}"#, id: "ses_timezone")

        try withTimeZone("UTC") {
            let utcBuckets = try ClaudeCodeUsageQuery.loadDailyBuckets(
                homeDirectoryURL: home,
                fileManager: .default,
                indexDatabaseURL: indexDatabaseURL
            )
            XCTAssertEqual(utcBuckets.map(\.day), [agentUsageDayIdentifier(for: usageDate)])
        }

        try withTimeZone("America/Los_Angeles") {
            let localBuckets = try ClaudeCodeUsageQuery.loadDailyBuckets(
                homeDirectoryURL: home,
                fileManager: .default,
                indexDatabaseURL: indexDatabaseURL
            )
            XCTAssertEqual(localBuckets.map(\.day), [agentUsageDayIdentifier(for: usageDate)])
        }
    }

    func testReplacingTranscriptIdentityForcesClaudeFullReplay() throws {
        let transcriptURL = projectsDir.appendingPathComponent("ses_identity.jsonl")
        let initialLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":10,"output_tokens":0}},"timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_identity"}"#
        let replacementFirstLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":3,"output_tokens":0}},"timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_identity"} "#
        let boundaryLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":20,"output_tokens":0}},"timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_identity","padding":"boundary-preserving-rewrite-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz"}"#
        let appendedLine = #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":30,"output_tokens":0}},"timestamp":"2026-07-22T09:02:05.000Z","cwd":"/tmp/project","sessionId":"ses_identity"}"#
        XCTAssertEqual(initialLine.utf8.count, replacementFirstLine.utf8.count)
        try (initialLine + "\n" + boundaryLine).write(to: transcriptURL, atomically: true, encoding: .utf8)

        _ = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        let originalFileNumber = (try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value

        try (replacementFirstLine + "\n" + boundaryLine + "\n" + appendedLine)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let replacementFileNumber = (try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        XCTAssertNotEqual(replacementFileNumber, originalFileNumber)

        let replaced = try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: home,
            fileManager: .default,
            indexDatabaseURL: indexDatabaseURL
        )
        XCTAssertEqual(replaced.dailyBuckets.first?.inputTokens, 53)
        XCTAssertEqual(replaced.dailyBuckets.first?.requestCount, 3)
    }

    func testLoadSnapshotIncludesSubagentTranscriptsUnderSubagentsDirectory() throws {
        // Real Claude Code writes Task-tool (subagent) transcripts sharing the parent
        // sessionId under <encoded-cwd>/<sessionId>/subagents/agent-<id>.jsonl. They
        // must be scanned and merged into the parent session.
        try writeTranscript("""
        {"type":"user","message":{"role":"user","content":"delegate"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_10"}
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":100,"output_tokens":20}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_10"}
        """, id: "ses_10")

        let sessionDir = projectsDir.appendingPathComponent("ses_10")
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let subagent = """
        {"type":"user","message":{"role":"user","content":"subtask"},"uuid":"u2","timestamp":"2026-07-22T09:01:00.000Z","cwd":"/tmp/project","sessionId":"ses_10"}
        {"type":"assistant","isSidechain":true,"agentId":"agent-x","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":50,"output_tokens":10}},"uuid":"a2","timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_10"}
        """
        try subagent.write(to: subagentsDir.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)

        XCTAssertEqual(snapshot.sessions.count, 1)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.id, "ses_10")
        XCTAssertEqual(session.tokensUsed, 180)
        XCTAssertEqual(session.inputTokens, 150)
        XCTAssertEqual(session.outputTokens, 30)
    }

    func testLoadDailyBucketsIncludesSubagentTranscriptsUnderSubagentsDirectory() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":100,"output_tokens":20}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_11"}
        """, id: "ses_11")

        let sessionDir = projectsDir.appendingPathComponent("ses_11")
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let subagent = """
        {"type":"assistant","isSidechain":true,"agentId":"agent-x","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":50,"output_tokens":10}},"uuid":"a2","timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_11"}
        """
        try subagent.write(to: subagentsDir.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)

        let day = agentUsageDayIdentifier(for: ISO8601DateFormatter().date(from: "2026-07-22T00:00:00Z")!)
        let bucket = try XCTUnwrap(buckets.first { $0.sessionID == "ses_11" && $0.day == day })
        XCTAssertEqual(bucket.requestCount, 2)
        XCTAssertEqual(bucket.inputTokens, 150)
        XCTAssertEqual(bucket.outputTokens, 30)
        XCTAssertEqual(bucket.totalTokens, 180)
    }

    func testLoadSnapshotResolvesMainTranscriptURLNotSubagent() throws {
        let mainURL = projectsDir.appendingPathComponent("ses_url.jsonl")
        let mainTranscript = """
        {"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_url"}
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_url"}
        """
        try mainTranscript.write(to: mainURL, atomically: true, encoding: .utf8)

        let sessionDir = projectsDir.appendingPathComponent("ses_url")
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let subagent = """
        {"type":"assistant","isSidechain":true,"agentId":"agent-x","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":5,"output_tokens":1}},"uuid":"a2","timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_url"}
        """
        try subagent.write(to: subagentsDir.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default, indexDatabaseURL: indexDatabaseURL)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.transcriptURL?.standardizedFileURL, mainURL.standardizedFileURL)
        XCTAssertEqual(session.tokensUsed, 18)
    }

    func testLoadTranscriptExtractsUserAndAssistantTextTurns() throws {
        let transcriptURL = projectsDir.appendingPathComponent("ses_turns.jsonl")
        let transcript = """
        {"type":"user","message":{"role":"user","content":"fix the crash"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_turns"}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>meta</local-command-caveat>"},"uuid":"u2","timestamp":"2026-07-22T09:00:01.000Z","cwd":"/tmp/project","sessionId":"ses_turns"}
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","content":[{"type":"thinking","thinking":"plan"},{"type":"text","text":"I found it"},{"type":"tool_use","id":"t1","name":"grep"}]},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_turns"}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let turns = try ClaudeCodeUsageQuery.loadTranscript(
            sessionID: "ses_turns",
            transcriptURL: transcriptURL,
            homeDirectoryURL: home,
            fileManager: .default
        )

        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns.map(\.text), ["fix the crash", "I found it"])
    }

    func testLoadTranscriptThrowsWhenFileMissing() {
        XCTAssertThrowsError(
            try ClaudeCodeUsageQuery.loadTranscript(sessionID: "missing", transcriptURL: nil, homeDirectoryURL: home, fileManager: .default)
        )
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
}
