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
}
