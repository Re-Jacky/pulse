import AppKit
import SwiftUI
import XCTest
@testable import Pulse

final class AgentStatusManagementViewTests: XCTestCase {
    func testLightColorMapsWorkingToGreenAndIdleToYellow() {
        XCTAssertEqual(
            NSColor(AgentStatusManagementView.color(for: .working)),
            NSColor.systemGreen
        )
        XCTAssertEqual(
            NSColor(AgentStatusManagementView.color(for: .idle)),
            NSColor.systemYellow
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

    func testSessionRowsIncludeSessionIDDetailLine() {
        let slot = makeSlot(
            agent: .codex,
            state: .working,
            sessionID: "session-123",
            projectPath: "/tmp/project",
            projectName: "project",
            sessionTitle: "Session"
        )

        XCTAssertEqual(
            AgentStatusManagementView.detailLineTexts(for: slot),
            ["Session", "Session ID: session-123", "/tmp/project"]
        )
    }

    func testSessionIDCopyActionWritesRawIDToPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()

        let didCopy = SessionIDCopyAction.copy("session-123", pasteboard: pasteboard)

        XCTAssertTrue(didCopy)
        XCTAssertEqual(pasteboard.string(forType: .string), "session-123")
    }

    private func makeSlot(
        agent: AgentStatusAgent,
        state: AgentSessionLightState,
        sessionID: String = UUID().uuidString,
        projectPath: String = "/tmp/project",
        projectName: String = "project",
        sessionTitle: String = "Session"
    ) -> AgentSessionSlot {
        AgentSessionSlot(
            id: UUID(),
            agent: agent,
            sessionID: sessionID,
            projectPath: projectPath,
            projectName: projectName,
            sessionTitle: sessionTitle,
            state: state,
            lastTransitionAt: nil,
            lastSeenAt: nil
        )
    }
}
