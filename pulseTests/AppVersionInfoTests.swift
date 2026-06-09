import XCTest
@testable import Pulse

final class AppVersionInfoTests: XCTestCase {
    func testAppDisplayNameUsesBundleVersion() {
        let info = AppVersionInfo(
            appVersion: "1.3.1",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        )

        XCTAssertEqual(info.appDisplayVersion, "Pulse 1.3.1")
    }

    func testAppDisplayNameFallsBackWhenVersionMissing() {
        let info = AppVersionInfo(
            appVersion: nil,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        )

        XCTAssertEqual(info.appDisplayVersion, "Pulse")
    }

    func testAppDisplayNameFallsBackWhenVersionBlank() {
        let info = AppVersionInfo(
            appVersion: "   ",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        )

        XCTAssertEqual(info.appDisplayVersion, "Pulse")
    }

    func testSystemDisplayVersionUsesMajorAndMinor() {
        let info = AppVersionInfo(
            appVersion: "1.3.1",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 1)
        )

        XCTAssertEqual(info.systemDisplayVersion, "macOS 15.0")
    }
}
