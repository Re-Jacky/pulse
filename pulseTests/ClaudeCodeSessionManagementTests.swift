import XCTest
@testable import Pulse

final class ClaudeCodeSessionManagementTests: XCTestCase {
    private func makeClaudeSession(id: String, cwd: String, updatedAt: TimeInterval) -> ClaudeCodeSessionRecord {
        ClaudeCodeSessionRecord(
            id: id,
            title: "Claude \(id)",
            cwd: cwd,
            model: "sonnet",
            modelProvider: "Claude",
            tokensUsed: 10,
            inputTokens: 10,
            outputTokens: 0,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")
        )
    }

    func testLoadManagedSessionsIncludesClaudeSessions() throws {
        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/missing-opencode.db") },
            loadOpenCodeSnapshot: { _ in OpenCodeUsageSnapshot(sessions: []) },
            loadOpenCodeTranscript: { _, _ in [] },
            loadCodexSnapshot: { CodexUsageSnapshot(sessions: []) },
            loadCodexTranscript: { _, _ in [] },
            loadCodexTranscriptProgressively: { _, _, _ in [] },
            loadClaudeCodeSnapshot: {
                ClaudeCodeUsageSnapshot(sessions: [
                    self.makeClaudeSession(id: "cc_1", cwd: "/tmp/pulse", updatedAt: 2_000)
                ])
            },
            loadClaudeCodeTranscript: { _, _ in [] },
            loadClaudeCodeTranscriptProgressively: { _, _, _ in [] }
        )

        let sessions = try repository.loadManagedSessions(enabledSources: Set([.claudeCode]))
        XCTAssertEqual(sessions.map(\.id), ["claudeCode::cc_1"])
        XCTAssertEqual(sessions.first?.source, .claudeCode)
        XCTAssertEqual(sessions.first?.rawSessionID, "cc_1")
        XCTAssertEqual(sessions.first?.projectPath, "/tmp/pulse")
        XCTAssertEqual(sessions.first?.transcriptURL, URL(fileURLWithPath: "/tmp/cc_1.jsonl"))
    }

    func testResumeActionForClaudeUsesClaudeCommand() throws {
        let repository = SessionManagementRepository()
        let session = ManagedSessionSummary(
            id: "claudeCode::cc_1",
            source: .claudeCode,
            rawSessionID: "cc_1",
            title: "t",
            projectPath: "/tmp",
            projectName: "pulse",
            subtitle: "Claude / sonnet",
            updatedAt: Date(),
            transcriptURL: nil
        )
        XCTAssertEqual(repository.resumeAction(for: session), .claudeCode(command: "claude --resume cc_1"))
    }
}
