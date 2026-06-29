import XCTest
@testable import Pulse

final class CodexSessionTranscriptTests: XCTestCase {
    func testCodexTranscriptLoaderReturnsUserAndAssistantTurnsInOrder() throws {
        let transcript = try loadCodexTranscriptFixture()

        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.text), ["Investigate the crash", "I found the nil path in AppDelegate."])
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
