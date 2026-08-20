import XCTest
@testable import Pulse

@MainActor
final class KeepAwakeSettingsTests: XCTestCase {
    private func makeSut(
        defaults: UserDefaults = {
            let d = UserDefaults(suiteName: "KeepAwakeSettingsTests")!
            d.removePersistentDomain(forName: "KeepAwakeSettingsTests")
            return d
        }()
    ) -> (settings: KeepAwakeSettings, defaults: UserDefaults) {
        let settings = KeepAwakeSettings(userDefaults: defaults)
        return (settings, defaults)
    }

    func test_initialState_defaultsToManualMode() {
        let (sut, _) = makeSut()
        XCTAssertEqual(sut.mode, .manual)
        XCTAssertFalse(sut.displaySleepOnly)
        XCTAssertEqual(sut.timerDuration, .indefinite)
        XCTAssertFalse(sut.isActive)
    }

    func test_setEnabled_createsAssertion() {
        let (sut, _) = makeSut()
        sut.setEnabled(true)
        XCTAssertTrue(sut.isActive)
    }

    func test_setDisabled_releasesAssertion() {
        let (sut, _) = makeSut()
        sut.setEnabled(true)
        sut.setEnabled(false)
        XCTAssertFalse(sut.isActive)
    }

    func test_persistsToUserDefaults() {
        let (sut, defaults) = makeSut()
        sut.setEnabled(true)
        XCTAssertEqual(defaults.string(forKey: "general.keepAwake.mode"), "manual")
        XCTAssertTrue(defaults.bool(forKey: "general.keepAwake.isActive"))
    }

    func test_restoreIfNeeded_restoresActiveState() {
        let defaults = UserDefaults(suiteName: "KeepAwakeSettingsTests2")!
        defaults.set(true, forKey: "general.keepAwake.isActive")
        defaults.set("manual", forKey: "general.keepAwake.mode")
        let sut = KeepAwakeSettings(userDefaults: defaults)
        sut.restoreIfNeeded()
        XCTAssertTrue(sut.isActive)
    }

    func test_smartMode_isSmartAvailable_trueWhenAgentLightsEnabledAndInstalled() {
        let sut = KeepAwakeSettings(
            agentLightsEnabled: { true },
            hasInstalledAgent: { true }
        )
        XCTAssertTrue(sut.isSmartAvailable)
    }

    func test_smartMode_isSmartAvailable_falseWhenAgentLightsDisabled() {
        let sut = KeepAwakeSettings(
            agentLightsEnabled: { false },
            hasInstalledAgent: { true }
        )
        XCTAssertFalse(sut.isSmartAvailable)
    }

    func test_smartMode_isSmartAvailable_falseWhenNoInstalledAgent() {
        let sut = KeepAwakeSettings(
            agentLightsEnabled: { true },
            hasInstalledAgent: { false }
        )
        XCTAssertFalse(sut.isSmartAvailable)
    }

    func test_smartMode_switchesToManualWhenNotAvailable() {
        let sut = KeepAwakeSettings(
            agentLightsEnabled: { false },
            hasInstalledAgent: { false }
        )
        sut.setMode(.smart)
        // Should fall back to manual since smart is not available
        XCTAssertEqual(sut.mode, .manual)
    }
}
