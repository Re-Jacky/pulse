import XCTest
@testable import Pulse

final class UpdateInstallPlannerTests: XCTestCase {
    func testPlannerBuildsContractFromInstalledBundleName() throws {
        let planner = UpdateInstallPlanner(fileManager: .default)
        let contract = try planner.makeContract(
            expectedVersion: "1.8.0",
            stagedAppURL: URL(fileURLWithPath: "/tmp/Pulse.app"),
            installedAppURL: URL(fileURLWithPath: "/Applications/PULSE.app")
        )

        XCTAssertEqual(contract.appBundleName, "PULSE.app")
        XCTAssertEqual(contract.backupAppPath, "/Applications/PULSE.backup.app")
        XCTAssertTrue(contract.relaunchMarkerPath.contains("Pulse/update-success"))
    }
}
