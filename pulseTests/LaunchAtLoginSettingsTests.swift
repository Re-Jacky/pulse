import XCTest
@testable import Pulse

final class MockLaunchAtLoginService: LaunchAtLoginService {
    var isEnabled: Bool
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        isEnabled = true
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        isEnabled = false
    }
}

private struct TestError: Error {}

final class LaunchAtLoginSettingsTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsToDisabled() {
        let settings = LaunchAtLoginSettings(
            service: MockLaunchAtLoginService(),
            userDefaults: freshDefaults()
        )

        XCTAssertFalse(settings.isEnabled)
        XCTAssertNil(settings.errorMessage)
    }

    func testEnableCallsRegisterAndPersists() {
        let defaults = freshDefaults()
        let service = MockLaunchAtLoginService()
        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)

        settings.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: LaunchAtLoginSettings.userDefaultsKey), true)
        XCTAssertNil(settings.errorMessage)
    }

    func testDisableCallsUnregisterAndPersists() {
        let defaults = freshDefaults()
        let service = MockLaunchAtLoginService(isEnabled: true)
        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)

        settings.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: LaunchAtLoginSettings.userDefaultsKey), false)
        XCTAssertNil(settings.errorMessage)
    }

    func testEnableFailureRevertsAndSetsError() {
        let defaults = freshDefaults()
        let service = MockLaunchAtLoginService()
        service.registerError = TestError()
        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)

        settings.setEnabled(true)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertEqual(defaults.bool(forKey: LaunchAtLoginSettings.userDefaultsKey), false)
    }

    func testDisableFailureRevertsAndSetsError() {
        let defaults = freshDefaults()
        let service = MockLaunchAtLoginService(isEnabled: true)
        service.unregisterError = TestError()
        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)

        settings.setEnabled(false)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertEqual(defaults.bool(forKey: LaunchAtLoginSettings.userDefaultsKey), true)
    }

    func testSuccessfulToggleClearsStaleError() {
        let defaults = freshDefaults()
        let service = MockLaunchAtLoginService()
        service.registerError = TestError()
        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)

        settings.setEnabled(true)
        XCTAssertNotNil(settings.errorMessage)

        service.registerError = nil
        settings.setEnabled(true)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertNil(settings.errorMessage)
    }

    func testRefreshSyncsFromServiceStatusAndClearsError() {
        let defaults = freshDefaults()
        let service = MockLaunchAtLoginService()
        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)
        settings.setEnabled(true)
        service.registerError = TestError()

        service.isEnabled = true
        settings.refresh()

        XCTAssertTrue(settings.isEnabled)
        XCTAssertNil(settings.errorMessage)
    }

    func testInitReadsLiveServiceStatusOverUserDefaults() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchAtLoginSettings.userDefaultsKey)
        let service = MockLaunchAtLoginService(isEnabled: false)

        let settings = LaunchAtLoginSettings(service: service, userDefaults: defaults)

        XCTAssertFalse(settings.isEnabled)
    }
}
