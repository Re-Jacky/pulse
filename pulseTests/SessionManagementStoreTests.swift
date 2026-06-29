import XCTest
@testable import Pulse

final class SessionManagementStoreTests: XCTestCase {
    func testManagedSessionSummaryUsesStableIdentityAcrossAgents() {
        let openCode = ManagedSessionSummary(
            id: "opencode::session-1",
            source: .openCode,
            rawSessionID: "session-1",
            title: "OpenCode Session",
            projectPath: "/tmp/project",
            projectName: "project",
            subtitle: "OpenCode",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let codex = ManagedSessionSummary(
            id: "codex::session-1",
            source: .codex,
            rawSessionID: "session-1",
            title: "Codex Session",
            projectPath: "/tmp/project",
            projectName: "project",
            subtitle: "Codex",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertNotEqual(openCode.id, codex.id)
    }

    func testTranscriptLoadStateLoadingValueIsDistinctFromIdleAndLoaded() {
        XCTAssertNotEqual(TranscriptLoadState.idle, .loading)
        XCTAssertNotEqual(TranscriptLoadState.loading, .loaded([]))
    }
}
