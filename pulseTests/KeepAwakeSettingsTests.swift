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

    func test_timerDuration_changes_updatesUserDefaults() {
        let (sut, defaults) = makeSut()
        sut.timerDuration = .h2
        XCTAssertEqual(defaults.string(forKey: "general.keepAwake.timerDuration"), "h2")
    }

    func test_displaySleepOnly_changes_persistsToUserDefaults() {
        let (sut, defaults) = makeSut()
        sut.displaySleepOnly = true
        XCTAssertTrue(defaults.bool(forKey: "general.keepAwake.displaySleepOnly"))
    }

    func test_mode_change_persistsToUserDefaults() {
        let defaults = UserDefaults(suiteName: "KeepAwakeSettingsTests5")!
        defaults.removePersistentDomain(forName: "KeepAwakeSettingsTests5")
        let sut = KeepAwakeSettings(
            userDefaults: defaults,
            agentLightsEnabled: { true },
            hasInstalledAgent: { true }
        )
        sut.setMode(.smart)
        XCTAssertEqual(defaults.string(forKey: "general.keepAwake.mode"), "smart")
    }

    func test_deactivate_resetsAllState() {
        let (sut, _) = makeSut()
        sut.setEnabled(true)
        sut.deactivate()
        XCTAssertFalse(sut.isActive)
    }

    func test_setEnabled_true_then_false_roundTrip() {
        let (sut, _) = makeSut()
        sut.setEnabled(true)
        XCTAssertTrue(sut.isActive)
        sut.setEnabled(false)
        XCTAssertFalse(sut.isActive)
        sut.setEnabled(true)
        XCTAssertTrue(sut.isActive)
    }

    func test_restoreIfNeeded_withExpiredTimer_deactivates() {
        let defaults = UserDefaults(suiteName: "KeepAwakeSettingsTests3")!
        defaults.set(true, forKey: "general.keepAwake.isActive")
        defaults.set("manual", forKey: "general.keepAwake.mode")
        defaults.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: "general.keepAwake.timerEndDate")
        defaults.set("h1", forKey: "general.keepAwake.timerDuration")
        let sut = KeepAwakeSettings(userDefaults: defaults)
        sut.restoreIfNeeded()
        XCTAssertFalse(sut.isActive)
    }

    func test_restoreIfNeeded_withSmartMode_notAvailable_deactivates() {
        let defaults = UserDefaults(suiteName: "KeepAwakeSettingsTests4")!
        defaults.set(true, forKey: "general.keepAwake.isActive")
        defaults.set("smart", forKey: "general.keepAwake.mode")
        let sut = KeepAwakeSettings(
            userDefaults: defaults,
            agentLightsEnabled: { false },
            hasInstalledAgent: { false }
        )
        sut.restoreIfNeeded()
        XCTAssertFalse(sut.isActive)
    }
}
