import XCTest
@testable import Pulse

final class AgentLightsSettingsTests: XCTestCase {
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

    func testEmptySavedSelectedAgentsRecoverToAllSupportedAgents() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set([], forKey: "agentLights.selectedAgents")

        let settings = AgentLightsSettings(userDefaults: defaults)

        XCTAssertEqual(settings.selectedAgents, Set(AgentStatusAgent.allCases))
    }

    func testEnabledAgentsUsesCanonicalStatusAgentOrderingWhenEnabled() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)
        settings.selectedAgents = [.codex]
        settings.isEnabled = true

        XCTAssertEqual(settings.enabledAgents, [.codex])
    }
}
