import AppKit
import XCTest
@testable import Pulse

final class AgentLightsSettingsTests: XCTestCase {
    func testOpenCodeStatusShowsRestartGuidance() {
        let status = AgentIntegrationStatus(
            agent: .openCode,
            state: .installedNeedsRestart,
            primaryActionTitle: "Reinstall",
            secondaryActions: ["Recheck", "Uninstall"],
            guidance: ["Restart OpenCode so the Pulse plugin is loaded."]
        )

        XCTAssertEqual(status.displayStateTitle, "Installed - Restart OpenCode")
        XCTAssertEqual(status.guidance.first, "Restart OpenCode so the Pulse plugin is loaded.")
    }

    func testCodexStatusShowsActivationGuidance() {
        let status = AgentIntegrationStatus(
            agent: .codex,
            state: .installedNeedsActivation,
            primaryActionTitle: "Reinstall",
            secondaryActions: ["Recheck", "Uninstall"],
            guidance: ["Open any Codex session.", "Open the Hooks view in Codex.", "Review the Pulse hook.", "Trust it so Codex can run it."]
        )

        XCTAssertEqual(status.displayStateTitle, "Installed - Activate in Codex")
        XCTAssertTrue(status.guidance.contains("Open the Hooks view in Codex."))
    }

    func testDefaultsToDisabledWithAllSupportedAgentsSelected() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.selectedAgents, Set(AgentStatusAgent.allCases))
        XCTAssertEqual(settings.enabledAgents, [])
    }

    func testEnabledAgentsIsEmptyWhenMasterToggleIsDisabled() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.selectedAgents = [.openCode]
        settings.isEnabled = false

        XCTAssertEqual(settings.enabledAgents, [])
    }

    func testEnabledStatePersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.isEnabled = true

        let restored = AgentLightsSettings(userDefaults: defaults)

        XCTAssertTrue(restored.isEnabled)
    }

    func testSelectedAgentsPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.selectedAgents = [.codex]

        let restored = AgentLightsSettings(userDefaults: defaults)

        XCTAssertEqual(restored.selectedAgents, [.codex])
    }

    func testInvalidSavedSelectedAgentsRecoverToAllSupportedAgents() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(["invalid-agent"], forKey: "agentLights.selectedAgents")

        let settings = AgentLightsSettings(userDefaults: defaults)

        XCTAssertEqual(settings.selectedAgents, Set(AgentStatusAgent.allCases))
    }

    func testEmptySavedSelectedAgentsRestoresToNoSelectedAgents() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set([], forKey: "agentLights.selectedAgents")

        let settings = AgentLightsSettings(userDefaults: defaults)

        XCTAssertEqual(settings.selectedAgents, [])
    }

    func testEmptySelectedAgentsPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.selectedAgents = []

        let restored = AgentLightsSettings(userDefaults: defaults)

        XCTAssertEqual(restored.selectedAgents, [])
    }

    func testEnabledAgentsUsesCanonicalStatusAgentOrderingWhenEnabled() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.selectedAgents = [.codex]
        settings.isEnabled = true

        XCTAssertEqual(settings.enabledAgents, [.codex])
    }

    func testAgentStatusPanelDefaultsAreTallEnoughForFirstOpen() {
        XCTAssertEqual(AgentStatusPanelMetrics.width, 460)
        XCTAssertEqual(AgentStatusPanelMetrics.height, 840)
        XCTAssertEqual(AgentStatusPanelMetrics.minHeight, 560)
    }

    @MainActor
    func testMenuBarStatusViewAcceptsPlainLeftClicks() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        view.configureForTesting(
            groups: [
                AgentStatusGroup(
                    agent: .openCode,
                    slots: [
                        AgentSessionSlot(
                            id: UUID(),
                            agent: .openCode,
                            sessionID: UUID().uuidString,
                            projectPath: "/tmp/project",
                            projectName: "project",
                            sessionTitle: "Session",
                            state: .working,
                            lastTransitionAt: nil,
                            lastSeenAt: nil
                        )
                    ],
                    overflowCount: 0
                )
            ],
            isEnabled: true,
            selectedAgents: [.openCode]
        )
        var selectedAgent: AgentStatusAgent?
        view.onLeftClickAgent = {
            selectedAgent = $0
        }

        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 10)) === view)

        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        )
        XCTAssertNotNil(downEvent)
        XCTAssertNotNil(upEvent)
        view.mouseDown(with: downEvent!)
        view.mouseUp(with: upEvent!)
        XCTAssertEqual(selectedAgent, .openCode)
    }

    @MainActor
    func testMenuBarStatusViewAddsGapBetweenAgentGroups() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode, .codex]
        )

        XCTAssertEqual(
            measuredStatusItemWidth(store: store, selectedAgents: [.openCode], defaults: defaults),
            35
        )
        XCTAssertEqual(
            measuredStatusItemWidth(store: store, selectedAgents: [.openCode, .codex], defaults: defaults),
            68
        )
    }

    @MainActor
    private func measuredStatusItemWidth(
        store: AgentStatusStore,
        selectedAgents: Set<AgentStatusAgent>,
        defaults: UserDefaults
    ) -> CGFloat? {
        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.isEnabled = true
        settings.selectedAgents = selectedAgents

        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        var measuredWidth: CGFloat?
        view.onPreferredWidthChange = { measuredWidth = $0 }
        view.bind(to: store, settings: settings)
        return measuredWidth
    }
}
