import XCTest
@testable import Pulse

final class ClaudeCodeTranscriptTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var projectsDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home")
        projectsDir = home.appendingPathComponent(".claude/projects/-Users-tmp-project")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        // ClaudeCodeUsageQuery persists its size+mtime transcript cache to the
        // real ~/Library/Caches/Pulse keyed by a stable hash of the (temp) home
        // directory. Remove exactly the file this test run wrote so we do not
        // leak cache files into the user's caches.
        try? FileManager.default.removeItem(at: claudeCacheFileURL())
    }

    private func claudeCacheFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("claude-code-transcript-cache-\(stableHash(home.path))-v1.json")
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)

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

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        XCTAssertEqual(snapshot.sessions.first?.title, "do the thing")
    }

    func testLoadDailyBucketsAggregatesAcrossDaysAndSessions() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_3"}
        {"type":"assistant","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":20,"output_tokens":4,"cache_read_input_tokens":6,"cache_creation_input_tokens":2}},"uuid":"a2","timestamp":"2026-07-22T10:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_3"}
        {"type":"assistant","message":{"id":"m3","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":5,"output_tokens":1}},"uuid":"a3","timestamp":"2026-07-23T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_4"}
        """, id: "ses_3")

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)

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

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.requestCount, 1)
    }

    func testLoadSnapshotIncludesZeroTokenUserOnlySession() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_6"}
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"never answered"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_6"}
        {"type":"last-prompt","lastPrompt":"never answered","leafUuid":"u1","sessionId":"ses_6"}
        """, id: "ses_6")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
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

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testLoadSnapshotCreatedAtIsSessionStartNotFirstAssistantMessage() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_8"}
        {"type":"user","message":{"role":"user","content":"typed first"},"uuid":"u1","timestamp":"2026-07-22T08:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_8"}
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":1,"output_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_8"}
        """, id: "ses_8")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T08:00:00Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:05Z")!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSecondLoadReusesCacheWhenTranscriptsUnchanged() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_9"}
        """, id: "ses_9")

        _ = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)
        _ = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        XCTAssertEqual(snapshot.sessions.map(\.id), ["ses_9"])
    }
}
