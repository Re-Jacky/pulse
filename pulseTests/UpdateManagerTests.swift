import XCTest
import CryptoKit
@testable import Pulse

final class UpdateManagerTests: XCTestCase {
    func testDefaultInstalledAppURLReturnsAppBundlePath() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Pulse.app/Contents/MacOS")

        XCTAssertEqual(UpdateManager.defaultInstalledAppURL(for: bundleURL), URL(fileURLWithPath: "/Applications/Pulse.app"))
    }

    func testAppBundleVersionReaderReadsMarketingVersionFromBundleInfoPlist() throws {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Pulse.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.8.0"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        XCTAssertEqual(try AppBundleVersionReader.marketingVersion(at: bundleURL), "1.8.0")
    }

    func testAppBundleVersionReaderRejectsMismatchedExpectedVersion() throws {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Pulse.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.7.9"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        XCTAssertThrowsError(try AppBundleVersionReader.validateExpectedVersion(at: bundleURL, expectedVersion: "1.8.0")) { error in
            XCTAssertEqual(error.localizedDescription, "The staged app version does not match the expected update version.")
        }
    }

    func testBeginInstallWritesContractAndLaunchesBundledUpdaterHelper() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let installedAppURL = tempRoot.appendingPathComponent("Applications/Pulse.app")
        let helperAppURL = tempRoot.appendingPathComponent("Pulse.app/Contents/Helpers/PulseUpdater.app")
        let stagedAppURL = tempRoot.appendingPathComponent("Staged/Pulse.app")
        try fileManager.createDirectory(at: installedAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: helperAppURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagedAppURL, withIntermediateDirectories: true)

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let launcher = LaunchRecorder()
        let defaults = UserDefaults(suiteName: #function)!
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: defaults,
            fileManager: fileManager,
            now: Date.init,
            installedAppURL: { installedAppURL },
            updaterAppURL: { helperAppURL },
            launchUpdater: launcher.record(appURL:contractURL:)
        )

        await manager.setStateForTesting(UpdateState.readyToInstall(
            release,
            stagedZipURL: tempRoot.appendingPathComponent("Pulse.zip"),
            stagedAppURL: stagedAppURL
        ))

        try await manager.beginInstall()

        XCTAssertEqual(manager.state, UpdateState.launchingInstaller(release))
        XCTAssertEqual(launcher.launchedAppURL, helperAppURL)

        let contractURL = try XCTUnwrap(launcher.contractURL)
        let data = try Data(contentsOf: contractURL)
        let contract = try JSONDecoder().decode(UpdateInstallContract.self, from: data)
        XCTAssertEqual(contract.expectedVersion, "1.8.0")
        XCTAssertEqual(contract.stagedAppPath, stagedAppURL.path)
        XCTAssertEqual(contract.installedAppPath, installedAppURL.path)
        XCTAssertEqual(defaults.string(forKey: UpdateManager.pendingLaunchMarkerKey), contract.relaunchMarkerPath)
    }

    func testBeginInstallFailsWhenBundledUpdaterHelperIsMissing() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let installedAppURL = tempRoot.appendingPathComponent("Applications/Pulse.app")
        let stagedAppURL = tempRoot.appendingPathComponent("Staged/Pulse.app")
        try fileManager.createDirectory(at: installedAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagedAppURL, withIntermediateDirectories: true)

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: fileManager,
            now: Date.init,
            installedAppURL: { installedAppURL },
            updaterAppURL: { tempRoot.appendingPathComponent("Missing/PulseUpdater.app") },
            launchUpdater: { _, _ in }
        )

        await manager.setStateForTesting(UpdateState.readyToInstall(
            release,
            stagedZipURL: tempRoot.appendingPathComponent("Pulse.zip"),
            stagedAppURL: stagedAppURL
        ))

        do {
            try await manager.beginInstall()
            XCTFail("Expected beginInstall to throw when helper is missing")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The bundled updater helper is missing.")
        }
    }

    func testAppReleasePicksZipAssetAndChecksumFromGitHubPayload() throws {
        let data = Data(
            """
            {
              "tag_name": "v1.8.0",
              "html_url": "https://github.com/example/pulse/releases/tag/v1.8.0",
              "body": "sha256: abc123",
              "assets": [
                {
                  "name": "Pulse-1.8.0.dmg",
                  "browser_download_url": "https://example.invalid/Pulse-1.8.0.dmg"
                },
                {
                  "name": "Pulse-1.8.0-updater.zip",
                  "browser_download_url": "https://example.invalid/Pulse-1.8.0-updater.zip"
                }
              ]
            }
            """.utf8
        )

        let release = try UpdateGitHubClient.parseLatestReleaseResponse(data)

        XCTAssertEqual(release.version, "1.8.0")
        XCTAssertEqual(release.zipAssetURL.absoluteString, "https://example.invalid/Pulse-1.8.0-updater.zip")
        XCTAssertEqual(release.checksum, "abc123")
    }

    func testVersionComparisonTreatsHigherMarketingVersionAsNewer() {
        XCTAssertTrue(AppVersionInfo(versionString: "1.8.0").isOlder(than: "1.8.1"))
        XCTAssertFalse(AppVersionInfo(versionString: "1.8.1").isOlder(than: "1.8.0"))
    }

    func testVersionComparisonTreatsMissingTrailingComponentsAsZero() {
        XCTAssertFalse(AppVersionInfo(versionString: "1.2").isOlder(than: "1.2.0"))
        XCTAssertFalse(AppVersionInfo(versionString: "1.2.0").isOlder(than: "1.2"))
    }

    func testReleaseParsingRejectsUnrelatedZipAssets() {
        let data = Data(
            """
            {
              "tag_name": "v1.8.0",
              "html_url": "https://github.com/example/pulse/releases/tag/v1.8.0",
              "body": "sha256: abc123",
              "assets": [
                {
                  "name": "Pulse-1.8.0-assets.zip",
                  "browser_download_url": "https://example.invalid/Pulse-1.8.0-assets.zip"
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(try UpdateGitHubClient.parseLatestReleaseResponse(data))
    }

    func testAutomaticCheckSkipsWhenLastSuccessWasWithin24Hours() {
        let now = Date(timeIntervalSince1970: 1_000)
        let lastCheck = now.addingTimeInterval(-60 * 60)

        XCTAssertFalse(UpdateCheckPolicy.shouldRunAutomaticCheck(now: now, lastSuccessfulCheckAt: lastCheck))
    }

    func testAutomaticCheckRunsWhenNoPreviousSuccessExists() {
        XCTAssertTrue(UpdateCheckPolicy.shouldRunAutomaticCheck(now: Date(), lastSuccessfulCheckAt: nil))
    }

    func testManualCheckPublishesUpdateAvailableWhenReleaseIsNewer() async throws {
        let client = StubUpdateClient(result: .success(AppRelease(
            version: "1.8.0",
            notesURL: URL(string: "https://example.invalid/release")!,
            zipAssetURL: URL(string: "https://example.invalid/Pulse-1.8.0-updater.zip")!,
            checksum: nil
        )))
        let defaults = UserDefaults(suiteName: #function)!
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: client,
            userDefaults: defaults,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        await manager.checkForUpdates(userInitiated: true)

        XCTAssertEqual(manager.state, .updateAvailable(client.release!))
        XCTAssertEqual(defaults.object(forKey: UpdateManager.lastSuccessfulCheckKey) as? Date, Date(timeIntervalSince1970: 2_000))
    }

    func testAutomaticCheckLeavesStateIdleWhenSkipped() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.set(Date(timeIntervalSince1970: 1_000 - 60 * 60), forKey: UpdateManager.lastSuccessfulCheckKey)
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(AppRelease(
                version: "1.8.0",
                notesURL: nil,
                zipAssetURL: URL(string: "https://example.invalid/Pulse-1.8.0-updater.zip")!,
                checksum: nil
            ))),
            userDefaults: defaults,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await manager.checkForUpdates(userInitiated: false)

        XCTAssertEqual(manager.state, .idle)
    }

    func testFailedUpdateCheckPublishesFailureState() async {
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .failure(LocalizedStubError(message: "boom"))),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init
        )

        await manager.checkForUpdates(userInitiated: true)

        XCTAssertEqual(manager.state, .failed(message: "boom"))
    }

    func testBeginInstallHelperLaunchFailsDoesNotStoreMarker() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let installedAppURL = tempRoot.appendingPathComponent("Applications/Pulse.app")
        let helperAppURL = tempRoot.appendingPathComponent("Pulse.app/Contents/Helpers/PulseUpdater.app")
        let stagedAppURL = tempRoot.appendingPathComponent("Staged/Pulse.app")
        try fileManager.createDirectory(at: installedAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: helperAppURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagedAppURL, withIntermediateDirectories: true)

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let defaults = UserDefaults(suiteName: #function)!
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: defaults,
            fileManager: fileManager,
            now: Date.init,
            installedAppURL: { installedAppURL },
            updaterAppURL: { helperAppURL },
            launchUpdater: { _, _ in throw StubError() }
        )

        await manager.setStateForTesting(UpdateState.readyToInstall(
            release,
            stagedZipURL: tempRoot.appendingPathComponent("Pulse.zip"),
            stagedAppURL: stagedAppURL
        ))

        do {
            try await manager.beginInstall()
            XCTFail("Expected beginInstall to throw when helper launch fails")
        } catch {
            XCTAssertTrue(error is StubError)
        }

        XCTAssertNil(defaults.string(forKey: UpdateManager.pendingLaunchMarkerKey))
    }

    func testBackupRestoreRecoversFromFailedRelaunch() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let installedAppURL = tempRoot.appendingPathComponent("Pulse.app")
        let backupAppURL = tempRoot.appendingPathComponent("Pulse.backup.app")

        try fileManager.createDirectory(at: installedAppURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupAppURL, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: backupAppURL.appendingPathComponent("version.txt"))

        let recovered = UpdateRecovery.attemptBackupRestore(
            fileManager: fileManager,
            backupAppURL: backupAppURL,
            installedAppURL: installedAppURL
        )

        XCTAssertTrue(recovered)
        XCTAssertTrue(fileManager.fileExists(atPath: installedAppURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: backupAppURL.path))
        XCTAssertEqual(try? String(contentsOf: installedAppURL.appendingPathComponent("version.txt")), "old")
    }

    func testBackupRestoreReturnsFalseWhenNoBackupExists() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let installedAppURL = tempRoot.appendingPathComponent("Pulse.app")
        let backupAppURL = tempRoot.appendingPathComponent("Pulse.backup.app")
        try fileManager.createDirectory(at: installedAppURL, withIntermediateDirectories: true)

        let recovered = UpdateRecovery.attemptBackupRestore(
            fileManager: fileManager,
            backupAppURL: backupAppURL,
            installedAppURL: installedAppURL
        )

        XCTAssertFalse(recovered)
    }

    func testAcknowledgeRelaunchWritesLaunchMarker() throws {
        let fileManager = FileManager.default
        let markerURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .failure(StubError())),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: fileManager,
            now: Date.init
        )

        try manager.writeLaunchSuccessMarker(to: markerURL)

        XCTAssertTrue(fileManager.fileExists(atPath: markerURL.path))
    }

    func testVerifyExpandedAppMovesStateToReadyToInstall() async throws {
        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init
        )

        let stagedZipURL = URL(fileURLWithPath: "/tmp/Pulse.zip")
        let stagedAppURL = URL(fileURLWithPath: "/tmp/Pulse.app")
        try FileManager.default.createDirectory(at: stagedAppURL, withIntermediateDirectories: true)

        try await manager.acceptVerifiedStagedUpdate(release: release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL)

        XCTAssertEqual(manager.state, .readyToInstall(release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL))

        try FileManager.default.removeItem(at: stagedAppURL)
    }

    func testUpToDateStateWhenVersionsMatch() async {
        let release = AppRelease(
            version: "1.7.3",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await manager.checkForUpdates(userInitiated: true)

        XCTAssertEqual(manager.state, .upToDate(lastCheckedAt: Date(timeIntervalSince1970: 1_000)))
    }

    func testDownloadAvailableUpdateNetworkFailure() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.onRequest = { _ in throw StubError() }

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init,
            urlSession: session,
            extractArchive: { _, _ in }
        )

        await manager.downloadAvailableUpdate(release)

        guard case .failed(let message) = manager.state else {
            return XCTFail("Expected failed state, got \(manager.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testDownloadAvailableUpdateHttpError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.onRequest = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: nil
        )
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init,
            urlSession: session,
            extractArchive: { _, _ in }
        )

        await manager.downloadAvailableUpdate(release)

        guard case .failed(let message) = manager.state else {
            return XCTFail("Expected failed state, got \(manager.state)")
        }
        XCTAssertEqual(message, "Download failed with HTTP status 404.")
    }

    func testDownloadAvailableUpdateChecksumMismatch() async {
        let zipData = Data("test zip content".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.onRequest = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, zipData)
        }

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: "does-not-match"
        )
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init,
            urlSession: session,
            extractArchive: { _, _ in }
        )

        await manager.downloadAvailableUpdate(release)

        guard case .failed(let message) = manager.state else {
            return XCTFail("Expected failed state, got \(manager.state)")
        }
        XCTAssertEqual(message, "Downloaded archive checksum does not match expected value.")
    }

    func testDownloadAvailableUpdateMissingPulseApp() async {
        let zipData = Data("test zip content".utf8)
        let actualHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.onRequest = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, zipData)
        }

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: actualHash
        )
        let fileManager = FileManager.default
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init,
            urlSession: session,
            extractArchive: { _, expandedDirectory in
                try fileManager.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)
            }
        )

        await manager.downloadAvailableUpdate(release)

        guard case .failed(let message) = manager.state else {
            return XCTFail("Expected failed state, got \(manager.state)")
        }
        XCTAssertEqual(message, "Expanded archive did not contain Pulse.app")
    }

    func testDownloadAvailableUpdateSuccess() async throws {
        let zipData = Data("test zip content".utf8)
        let actualHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.onRequest = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, zipData)
        }

        let release = AppRelease(
            version: "1.8.0",
            notesURL: nil,
            zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
            checksum: actualHash
        )
        let fileManager = FileManager.default
        let manager = UpdateManager(
            currentVersion: "1.7.3",
            client: StubUpdateClient(result: .success(release)),
            userDefaults: UserDefaults(suiteName: #function)!,
            fileManager: .default,
            now: Date.init,
            urlSession: session,
            extractArchive: { _, expandedDirectory in
                try fileManager.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: expandedDirectory.appendingPathComponent("Pulse.app"), withIntermediateDirectories: true)
            }
        )

        await manager.downloadAvailableUpdate(release)

        guard case .readyToInstall(let stateRelease, let stagedZipURL, let stagedAppURL) = manager.state else {
            return XCTFail("Expected readyToInstall state, got \(manager.state)")
        }
        XCTAssertEqual(stateRelease.version, "1.8.0")
        XCTAssertTrue(stagedZipURL.lastPathComponent.hasPrefix("Pulse-"))
        XCTAssertTrue(stagedZipURL.lastPathComponent.hasSuffix("-updater.zip"))
        XCTAssertEqual(stagedAppURL.lastPathComponent, "Pulse.app")
    }
}

private final class LaunchRecorder {
    private(set) var launchedAppURL: URL?
    private(set) var contractURL: URL?

    func record(appURL: URL, contractURL: URL) {
        launchedAppURL = appURL
        self.contractURL = contractURL
    }
}

private struct StubError: Error {}

private struct LocalizedStubError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class StubUpdateClient: UpdateClient {
    let result: Result<AppRelease, Error>

    var release: AppRelease? {
        try? result.get()
    }

    init(result: Result<AppRelease, Error>) {
        self.result = result
    }

    func fetchLatestRelease() async throws -> AppRelease {
        try result.get()
    }
}

private final class MockURLProtocol: URLProtocol {
    static var onRequest: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.onRequest else {
            fatalError("MockURLProtocol.onRequest not set")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
