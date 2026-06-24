import AppKit
import XCTest
@testable import Pulse

@MainActor
final class MenuBarStatusItemViewTests: XCTestCase {
    func testLightColorMapsWorkingToGreenAndIdleToYellow() {
        XCTAssertEqual(
            MenuBarStatusItemView.color(for: .working),
            NSColor.systemGreen
        )
        XCTAssertEqual(
            MenuBarStatusItemView.color(for: .idle),
            NSColor.systemYellow
        )
    }

    func testPrimaryClickActivatesOnInsideRelease() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        var clickCount = 0
        view.onLeftClick = {
            clickCount += 1
        }

        view.performLeftMouseDownForTesting(at: NSPoint(x: 10, y: 11))
        XCTAssertEqual(clickCount, 0)

        view.performLeftMouseUpForTesting(at: NSPoint(x: 10, y: 11))
        XCTAssertEqual(clickCount, 1)
    }

    func testPrimaryClickUsesResolvedAgentCallback() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        view.configureForTesting(
            groups: [
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
            ],
            isEnabled: true,
            selectedAgents: [.openCode, .codex]
        )

        var selectedAgent: AgentStatusAgent?
        view.onLeftClickAgent = { selectedAgent = $0 }

        view.performLeftMouseDownForTesting(at: NSPoint(x: 8, y: 11))
        view.performLeftMouseUpForTesting(at: NSPoint(x: 8, y: 11))

        XCTAssertEqual(selectedAgent, .openCode)
    }

    func testClickInOpenCodeGroupResolvesOpenCodeAgent() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        view.configureForTesting(
            groups: [
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
            ],
            isEnabled: true,
            selectedAgents: [.openCode, .codex]
        )

        XCTAssertEqual(view.agent(at: NSPoint(x: 8, y: 11)), .openCode)
    }

    func testOverflowMarkerBelongsToItsAgentGroup() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
        view.configureForTesting(
            groups: [
                AgentStatusGroup(
                    agent: .openCode,
                    slots: Array(repeating: makeSlot(agent: .openCode, state: .working), count: 4),
                    overflowCount: 1
                )
            ],
            isEnabled: true,
            selectedAgents: [.openCode]
        )

        XCTAssertEqual(view.agent(at: NSPoint(x: 62, y: 11)), .openCode)
    }

    func testTwoDigitOverflowMarkerKeepsItsFullClickableRegion() throws {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        view.configureForTesting(
            groups: [
                AgentStatusGroup(
                    agent: .openCode,
                    slots: Array(repeating: makeSlot(agent: .openCode, state: .working), count: 4),
                    overflowCount: 12
                )
            ],
            isEnabled: true,
            selectedAgents: [.openCode]
        )

        let groupFrame = try XCTUnwrap(view.groupFrame(for: .openCode))
        XCTAssertEqual(view.agent(at: NSPoint(x: 70, y: 11)), .openCode)
        XCTAssertEqual(view.agent(at: NSPoint(x: groupFrame.maxX - 1, y: groupFrame.midY)), .openCode)
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
