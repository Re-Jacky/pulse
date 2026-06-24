import XCTest
@testable import Pulse

final class AgentStatusManagementViewTests: XCTestCase {
    func testLightColorMapsWorkingToGreenAndIdleToYellow() {
        XCTAssertEqual(
            AgentStatusManagementView.color(for: .working),
            .green
        )
        XCTAssertEqual(
            AgentStatusManagementView.color(for: .idle),
            .yellow
        )
    }

    func testSelectedAgentGroupReturnsOnlyMatchingGroup() {
        let groups = [
            AgentStatusGroup(
                agent: .openCode,
                slots: [makeSlot(agent: .openCode, state: .working)],
                overflowCount: 0
            ),
            AgentStatusGroup(
                agent: .codex,
                slots: [makeSlot(agent: .codex, state: .idle)],
                overflowCount: 0
            )
        ]

        XCTAssertEqual(
            AgentStatusManagementView.visibleGroups(groups, selectedAgent: .codex).map(\.agent),
            [.codex]
        )
    }

    @MainActor
    func testVisibleGroupsFollowMutablePanelSelection() {
        let groups = [
            AgentStatusGroup(
                agent: .openCode,
                slots: [makeSlot(agent: .openCode, state: .working)],
                overflowCount: 0
            ),
            AgentStatusGroup(
                agent: .codex,
                slots: [makeSlot(agent: .codex, state: .idle)],
                overflowCount: 0
            )
        ]
        let selection = AgentStatusPanelSelection(selectedAgent: .openCode)

        XCTAssertEqual(
            AgentStatusManagementView.visibleGroups(groups, selection: selection).map(\.agent),
            [.openCode]
        )

        selection.selectedAgent = .codex

        XCTAssertEqual(
            AgentStatusManagementView.visibleGroups(groups, selection: selection).map(\.agent),
            [.codex]
        )
    }

    func testTooltipVisibilityRequiresHoverAndTooltipText() {
        XCTAssertFalse(TooltipPresentation.shouldShowTooltip(isHovering: false, tooltip: "/tmp/project"))
        XCTAssertFalse(TooltipPresentation.shouldShowTooltip(isHovering: true, tooltip: ""))
        XCTAssertTrue(TooltipPresentation.shouldShowTooltip(isHovering: true, tooltip: "/tmp/project"))
    }

    private func makeSlot(
        agent: AgentStatusAgent,
        state: AgentSessionLightState
    ) -> AgentSessionSlot {
        AgentSessionSlot(
            id: UUID(),
            agent: agent,
            sessionID: UUID().uuidString,
            projectPath: "/tmp/project",
            projectName: "project",
            sessionTitle: "Session",
            state: state,
            lastTransitionAt: nil,
            lastSeenAt: nil
        )
    }
}
