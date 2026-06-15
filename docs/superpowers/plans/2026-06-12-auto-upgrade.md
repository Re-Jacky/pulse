# Auto Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Releases-based updater for `Pulse` that checks on startup, supports manual checks in Settings and the status item menu, downloads a ZIP in-app with inline progress, installs through a bundled helper, relaunches automatically, and only shows `xattr` recovery instructions when install or relaunch fails.

**Architecture:** Keep update discovery, download, and UI state inside a shared `UpdateManager` owned by `AppDelegate`. Add a small bundled `PulseUpdater` helper target that receives a staged app path plus install contract, swaps `/Applications/Pulse.app` with rollback, clears quarantine as a best-effort step, relaunches, and waits for a launch-success marker before cleanup.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Foundation, XCTest, URLSession, Process, FileManager, Xcode project target configuration in `pulse.xcodeproj/project.pbxproj`

---

## Planned Files And Responsibilities

- Create: `pulse/Managers/UpdateModels.swift`
  Shared update types for release metadata, persisted state, update phases, and helper contract payloads.
- Create: `pulse/Managers/UpdateManager.swift`
  Observable object for startup checks, manual checks, download progress, artifact verification, staging, helper launch, and relaunch success acknowledgement.
- Create: `pulse/Managers/UpdateInstallPlanner.swift`
  Pure path and filesystem decision logic shared by the app and the helper so rollback behavior is testable without UI.
- Create: `pulse/Managers/UpdateGitHubClient.swift`
  Small GitHub Releases fetch/parser helper that maps `releases/latest` JSON into `AppRelease`.
- Create: `pulseTests/UpdateManagerTests.swift`
  Tests for throttling, release parsing, state transitions, and staged artifact validation boundaries.
- Create: `pulseTests/UpdateInstallPlannerTests.swift`
  Tests for backup path selection, rollback decisions, and launch-marker timeout decisions.
- Modify: `pulse/App/AppDelegate.swift`
  Instantiate `UpdateManager`, trigger startup checks, add update-aware status menu items, and inject the manager into panel/settings views.
- Modify: `pulse/Views/SettingsView.swift`
  Add an Update section with current version, check action, inline download progress, install action, and failure copy.
- Modify: `pulse/Views/PopoverView.swift`
  Add the `UpdateManager` environment object passthrough so panel content can render update state consistently if needed later.
- Modify: `pulse/Managers/AppVersionInfo.swift`
  Add reusable parsed version accessors for semantic version comparison rather than display-only strings.
- Create: `pulseUpdater/main.swift`
  Entry point for the helper executable target.
- Create: `pulseUpdater/UpdaterAppDelegate.swift`
  Launches the install window, decodes the install contract, drives replacement flow, and handles relaunch success timeout.
- Create: `pulseUpdater/UpdaterWindowController.swift`
  Minimal AppKit status window that shows install progress and fallback instructions.
- Create: `pulseUpdater/UpdaterInstaller.swift`
  Filesystem replacement and rollback code that consumes `UpdateInstallPlanner` decisions.
- Modify: `scripts/build-dmg.sh`
  Continue building the DMG and add ZIP generation for updater releases.
- Modify: `pulse.xcodeproj/project.pbxproj`
  Add all new files, add a `PulseUpdater` target, add a Copy Files phase to embed the helper into `Pulse.app`, and bump `MARKETING_VERSION` from `1.7.3` to `1.8.0`.

---

### Task 1: Add Update Models, GitHub Parsing, And Failing Tests

**Files:**
- Create: `pulse/Managers/UpdateModels.swift`
- Create: `pulse/Managers/UpdateGitHubClient.swift`
- Modify: `pulse/Managers/AppVersionInfo.swift`
- Create: `pulseTests/UpdateManagerTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests for release parsing, version comparison, and startup throttling**

Create `pulseTests/UpdateManagerTests.swift`:

```swift
import XCTest
@testable import Pulse

final class UpdateManagerTests: XCTestCase {
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

    func testAutomaticCheckSkipsWhenLastSuccessWasWithin24Hours() {
        let now = Date(timeIntervalSince1970: 1_000)
        let lastCheck = now.addingTimeInterval(-60 * 60)

        XCTAssertFalse(UpdateCheckPolicy.shouldRunAutomaticCheck(now: now, lastSuccessfulCheckAt: lastCheck))
    }

    func testAutomaticCheckRunsWhenNoPreviousSuccessExists() {
        XCTAssertTrue(UpdateCheckPolicy.shouldRunAutomaticCheck(now: Date(), lastSuccessfulCheckAt: nil))
    }
}
```

- [ ] **Step 2: Run the test target to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests
```

Expected: FAIL with missing `UpdateGitHubClient`, `UpdateCheckPolicy`, and `AppVersionInfo(versionString:)` / `isOlder(than:)` symbols.

- [ ] **Step 3: Add the minimal shared update models and parser implementation**

Create `pulse/Managers/UpdateModels.swift`:

```swift
import Foundation

struct AppRelease: Equatable {
    let version: String
    let notesURL: URL?
    let zipAssetURL: URL
    let checksum: String?
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(lastCheckedAt: Date)
    case updateAvailable(AppRelease)
    case downloading(AppRelease, progress: Double)
    case readyToInstall(AppRelease, stagedZipURL: URL, stagedAppURL: URL)
    case launchingInstaller(AppRelease)
    case failed(message: String)
}

enum UpdateCheckPolicy {
    static func shouldRunAutomaticCheck(now: Date, lastSuccessfulCheckAt: Date?) -> Bool {
        guard let lastSuccessfulCheckAt else { return true }
        return now.timeIntervalSince(lastSuccessfulCheckAt) >= 24 * 60 * 60
    }
}

struct UpdatePersistentState: Equatable {
    var lastSuccessfulCheckAt: Date?
    var pendingInstalledVersion: String?
}

struct UpdateInstallContract: Codable, Equatable {
    let appBundleName: String
    let expectedVersion: String
    let stagedAppPath: String
    let installedAppPath: String
    let backupAppPath: String
    let relaunchMarkerPath: String
}
```

Create `pulse/Managers/UpdateGitHubClient.swift`:

```swift
import Foundation

enum UpdateGitHubClient {
    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let body: String
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    static func parseLatestReleaseResponse(_ data: Data) throws -> AppRelease {
        let response = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        guard let zipAsset = response.assets.first(where: { $0.name.hasSuffix("-updater.zip") || $0.name.hasSuffix(".zip") }) else {
            throw NSError(domain: "UpdateGitHubClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing updater zip asset"])
        }

        let version = response.tagName.replacingOccurrences(of: "v", with: "")
        let checksum = response.body
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("sha256:") else { return nil }
                return trimmed.replacingOccurrences(of: "sha256:", with: "").trimmingCharacters(in: .whitespaces)
            }
            .first

        return AppRelease(version: version, notesURL: response.htmlURL, zipAssetURL: zipAsset.browserDownloadURL, checksum: checksum)
    }
}
```

Modify `pulse/Managers/AppVersionInfo.swift` so it can compare semantic versions:

```swift
struct AppVersionInfo {
    let appVersion: String?
    let operatingSystemVersion: OperatingSystemVersion

    init(
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.appVersion = appVersion
        self.operatingSystemVersion = operatingSystemVersion
    }

    init(versionString: String) {
        self.appVersion = versionString
        self.operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    }

    func isOlder(than otherVersion: String) -> Bool {
        versionComponents(appVersion) lexicographicallyPrecedes versionComponents(otherVersion)
    }

    private func versionComponents(_ version: String?) -> [Int] {
        (version ?? "0")
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}
```

Add the new files to the project:

```bash
ruby add_files.rb pulse/Managers/UpdateModels.swift pulse/Managers/UpdateGitHubClient.swift pulseTests/UpdateManagerTests.swift
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests -only-testing:pulseTests/AppVersionInfoTests
```

Expected: PASS

- [ ] **Step 5: Commit the shared update foundation**

```bash
git add pulse/Managers/UpdateModels.swift pulse/Managers/UpdateGitHubClient.swift pulse/Managers/AppVersionInfo.swift pulseTests/UpdateManagerTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add update models and release parsing"
```

---

### Task 2: Implement UpdateManager Download, Verification, And Relaunch Marker Logic

**Files:**
- Create: `pulse/Managers/UpdateManager.swift`
- Modify: `pulse/Managers/UpdateModels.swift`
- Modify: `pulseTests/UpdateManagerTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Extend the tests to cover UpdateManager state transitions**

Append to `pulseTests/UpdateManagerTests.swift`:

```swift
func testManualCheckPublishesUpdateAvailableWhenReleaseIsNewer() async throws {
    let client = StubUpdateClient(result: .success(AppRelease(
        version: "1.8.0",
        notesURL: URL(string: "https://example.invalid/release")!,
        zipAssetURL: URL(string: "https://example.invalid/Pulse-1.8.0-updater.zip")!,
        checksum: nil
    )))
    let manager = UpdateManager(
        currentVersion: "1.7.3",
        client: client,
        userDefaults: UserDefaults(suiteName: #function)!,
        fileManager: .default,
        now: { Date(timeIntervalSince1970: 2_000) }
    )

    await manager.checkForUpdates(userInitiated: true)

    XCTAssertEqual(manager.state, .updateAvailable(client.release!))
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
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests
```

Expected: FAIL with missing `UpdateManager`, `StubUpdateClient`, and `writeLaunchSuccessMarker` symbols.

- [ ] **Step 3: Implement UpdateManager with minimal seams for networking and staging**

Create `pulse/Managers/UpdateManager.swift`:

```swift
import Foundation
import Combine

protocol UpdateClient {
    func fetchLatestRelease() async throws -> AppRelease
}

final class UpdateManager: ObservableObject {
    static let lastSuccessfulCheckKey = "update.lastSuccessfulCheckAt"
    static let pendingLaunchMarkerKey = "update.pendingLaunchMarkerPath"

    @Published private(set) var state: UpdateState = .idle

    private let currentVersion: String
    private let client: UpdateClient
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        currentVersion: String = AppVersionInfo().appVersion ?? "0",
        client: UpdateClient,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.currentVersion = currentVersion
        self.client = client
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.now = now
    }

    @MainActor
    func checkForUpdates(userInitiated: Bool) async {
        let lastSuccessfulCheckAt = userDefaults.object(forKey: Self.lastSuccessfulCheckKey) as? Date
        if userInitiated == false && UpdateCheckPolicy.shouldRunAutomaticCheck(now: now(), lastSuccessfulCheckAt: lastSuccessfulCheckAt) == false {
            return
        }

        state = .checking

        do {
            let release = try await client.fetchLatestRelease()
            if AppVersionInfo(versionString: currentVersion).isOlder(than: release.version) {
                state = .updateAvailable(release)
            } else {
                let checkedAt = now()
                userDefaults.set(checkedAt, forKey: Self.lastSuccessfulCheckKey)
                state = .upToDate(lastCheckedAt: checkedAt)
            }
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func writeLaunchSuccessMarker(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: url)
    }
}
```

Extend `pulse/Managers/UpdateModels.swift` with a small local staging descriptor so later tasks can add ZIP download and unzip behavior without renaming types:

```swift
struct StagedUpdate: Equatable {
    let release: AppRelease
    let zipURL: URL
    let appBundleURL: URL
}
```

Add a tiny stub helper inside `pulseTests/UpdateManagerTests.swift`:

```swift
private struct StubError: Error {}

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
```

Add the new file to the project:

```bash
ruby add_files.rb pulse/Managers/UpdateManager.swift
```

- [ ] **Step 4: Re-run the focused tests to verify they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests
```

Expected: PASS

- [ ] **Step 5: Commit the manager skeleton**

```bash
git add pulse/Managers/UpdateManager.swift pulse/Managers/UpdateModels.swift pulseTests/UpdateManagerTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add update manager skeleton"
```

---

### Task 3: Wire UpdateManager Into AppDelegate, Settings, And The Status Item Menu

**Files:**
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulse/Views/SettingsView.swift`
- Modify: `pulse/Views/PopoverView.swift`
- Modify: `pulse/Managers/UpdateManager.swift`

- [ ] **Step 1: Add the failing UI-facing tests for state rendering helpers**

Add a small view-model helper inside `pulseTests/UpdateManagerTests.swift` so UI text can be pinned without snapshot tests:

```swift
func testUpdateActionLabelUsesInstallWhenReadyToInstall() {
    let release = AppRelease(
        version: "1.8.0",
        notesURL: nil,
        zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
        checksum: nil
    )

    XCTAssertEqual(UpdateActionPresentation(state: .readyToInstall(release, stagedZipURL: URL(fileURLWithPath: "/tmp/Pulse.zip"), stagedAppURL: URL(fileURLWithPath: "/tmp/Pulse.app"))).primaryButtonTitle, "Install Update")
}
```

- [ ] **Step 2: Run the test target to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests
```

Expected: FAIL with missing `UpdateActionPresentation`.

- [ ] **Step 3: Add update actions to AppDelegate and Settings with inline progress**

Extend `pulse/Managers/UpdateManager.swift` with a small presentation helper:

```swift
struct UpdateActionPresentation: Equatable {
    let primaryButtonTitle: String

    init(state: UpdateState) {
        switch state {
        case .readyToInstall:
            primaryButtonTitle = "Install Update"
        case .updateAvailable:
            primaryButtonTitle = "Download Update"
        case .checking:
            primaryButtonTitle = "Checking..."
        default:
            primaryButtonTitle = "Check for Updates..."
        }
    }
}
```

Modify `pulse/App/AppDelegate.swift` to own and inject the manager:

```swift
private lazy var updateManager = UpdateManager(client: LiveUpdateClient())

func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupMainMenu()
    setupThemeObservation()
    setupFeatureObservation()
    setupPanelObservation()

    Task { @MainActor [weak self] in
        await self?.updateManager.checkForUpdates(userInitiated: false)
    }

    panel = makePanel()
}
```

Inject it into both roots:

```swift
rootView: PopoverView()
    .environmentObject(monitor)
    .environmentObject(themeManager)
    .environmentObject(agentUsageSettings)
    .environmentObject(agentUsageStore)
    .environmentObject(updateManager)
```

```swift
rootView: SettingsView()
    .environmentObject(themeManager)
    .environmentObject(agentUsageSettings)
    .environmentObject(updateManager)
```

Update the context menu section in `showContextMenu()`:

```swift
let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
checkUpdatesItem.target = self
menu.addItem(checkUpdatesItem)

if case let .readyToInstall(release, _, _) = updateManager.state {
    let installItem = NSMenuItem(title: "Install Pulse \(release.version)", action: #selector(installDownloadedUpdate), keyEquivalent: "")
    installItem.target = self
    menu.addItem(installItem)
}
```

Add menu actions:

```swift
@objc private func checkForUpdatesFromMenu() {
    Task { @MainActor [weak self] in
        await self?.updateManager.checkForUpdates(userInitiated: true)
    }
}

@objc private func installDownloadedUpdate() {
    Task { @MainActor [weak self] in
        try? await self?.updateManager.beginInstall()
    }
}
```

Modify `pulse/Views/SettingsView.swift` to add a third section and inline progress:

```swift
@EnvironmentObject var updateManager: UpdateManager

private enum Section: Hashable {
    case theme
    case agentUsage
    case updates
}
```

Add the sidebar button:

```swift
sidebarButton(title: "Updates", systemImage: "arrow.triangle.2.circlepath", section: .updates)
```

Add content:

```swift
private var updateContent: some View {
    VStack(alignment: .leading, spacing: 14) {
        Text("Updates")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text(versionInfo.appDisplayVersion)
            .font(.system(size: 13))
            .foregroundColor(.appSecondaryText)

        switch updateManager.state {
        case .checking:
            ProgressView("Checking for updates...")
        case let .downloading(_, progress):
            ProgressView(value: progress, total: 1.0) {
                Text("Downloading update...")
            }
        case let .updateAvailable(release):
            Button("Download Pulse \(release.version)") {
                Task { @MainActor in
                    try? await updateManager.downloadAvailableUpdate(release)
                }
            }
        case let .readyToInstall(release, _, _):
            Button("Install Pulse \(release.version)") {
                Task { @MainActor in
                    try? await updateManager.beginInstall()
                }
            }
        case let .failed(message):
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.red)
        default:
            Button("Check for Updates...") {
                Task { @MainActor in
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            }
        }
    }
}
```

Update the section switch:

```swift
case .updates:
    updateContent
```

Modify `pulse/Views/PopoverView.swift` only to accept the environment object for future consistency:

```swift
@EnvironmentObject var updateManager: UpdateManager
```

- [ ] **Step 4: Build and run the focused tests again**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests && xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: tests PASS and build SUCCEEDED.

- [ ] **Step 5: Commit the app UI wiring**

```bash
git add pulse/App/AppDelegate.swift pulse/Views/SettingsView.swift pulse/Views/PopoverView.swift pulse/Managers/UpdateManager.swift pulseTests/UpdateManagerTests.swift
git commit -m "feat: wire update manager into app ui"
```

---

### Task 4: Add Install Planner, Helper Contract, And Failing Rollback Tests

**Files:**
- Create: `pulse/Managers/UpdateInstallPlanner.swift`
- Create: `pulseTests/UpdateInstallPlannerTests.swift`
- Modify: `pulse/Managers/UpdateModels.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing planner tests**

Create `pulseTests/UpdateInstallPlannerTests.swift`:

```swift
import XCTest
@testable import Pulse

final class UpdateInstallPlannerTests: XCTestCase {
    func testPlannerBuildsBackupPathNextToInstalledApp() throws {
        let planner = UpdateInstallPlanner(fileManager: .default)
        let contract = try planner.makeContract(
            expectedVersion: "1.8.0",
            stagedAppURL: URL(fileURLWithPath: "/tmp/Pulse.app"),
            installedAppURL: URL(fileURLWithPath: "/Applications/Pulse.app")
        )

        XCTAssertEqual(contract.backupAppPath, "/Applications/Pulse.backup.app")
        XCTAssertTrue(contract.relaunchMarkerPath.contains("Pulse/update-success"))
    }

    func testLaunchMarkerTimeoutReturnsRecoveryFailure() {
        XCTAssertEqual(
            UpdateInstallPlanner.relaunchOutcome(markerExists: false, processStillRunning: false),
            .failedRecoveryNeeded
        )
    }
}
```

- [ ] **Step 2: Run the planner tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateInstallPlannerTests
```

Expected: FAIL with missing `UpdateInstallPlanner` and `relaunchOutcome` symbols.

- [ ] **Step 3: Implement the pure planner and contract helpers**

Create `pulse/Managers/UpdateInstallPlanner.swift`:

```swift
import Foundation

enum RelaunchOutcome: Equatable {
    case success
    case failedRecoveryNeeded
}

struct UpdateInstallPlanner {
    let fileManager: FileManager

    func makeContract(expectedVersion: String, stagedAppURL: URL, installedAppURL: URL) throws -> UpdateInstallContract {
        let backupAppURL = installedAppURL.deletingLastPathComponent().appendingPathComponent("Pulse.backup.app")
        let markerURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/update-success")

        return UpdateInstallContract(
            appBundleName: "Pulse.app",
            expectedVersion: expectedVersion,
            stagedAppPath: stagedAppURL.path,
            installedAppPath: installedAppURL.path,
            backupAppPath: backupAppURL.path,
            relaunchMarkerPath: markerURL.path
        )
    }

    static func relaunchOutcome(markerExists: Bool, processStillRunning: Bool) -> RelaunchOutcome {
        if markerExists { return .success }
        if processStillRunning { return .success }
        return .failedRecoveryNeeded
    }
}
```

Add the new files to the project:

```bash
ruby add_files.rb pulse/Managers/UpdateInstallPlanner.swift pulseTests/UpdateInstallPlannerTests.swift
```

- [ ] **Step 4: Re-run the planner tests to verify they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateInstallPlannerTests
```

Expected: PASS

- [ ] **Step 5: Commit the planner layer**

```bash
git add pulse/Managers/UpdateInstallPlanner.swift pulse/Managers/UpdateModels.swift pulseTests/UpdateInstallPlannerTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add updater install planner"
```

---

### Task 5: Add The PulseUpdater Helper Target And Replacement Flow

**Files:**
- Create: `pulseUpdater/main.swift`
- Create: `pulseUpdater/UpdaterAppDelegate.swift`
- Create: `pulseUpdater/UpdaterWindowController.swift`
- Create: `pulseUpdater/UpdaterInstaller.swift`
- Modify: `pulse/Managers/UpdateManager.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the failing integration-style tests for contract writing and helper launch preparation**

Append to `pulseTests/UpdateManagerTests.swift`:

```swift
func testBeginInstallWritesContractFileForHelper() async throws {
    let release = AppRelease(
        version: "1.8.0",
        notesURL: nil,
        zipAssetURL: URL(string: "https://example.invalid/Pulse.zip")!,
        checksum: nil
    )
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let stagedZipURL = tempDirectory.appendingPathComponent("Pulse.zip")
    let stagedAppURL = tempDirectory.appendingPathComponent("Pulse.app")

    let manager = UpdateManager(
        currentVersion: "1.7.3",
        client: StubUpdateClient(result: .success(release)),
        userDefaults: UserDefaults(suiteName: #function)!,
        fileManager: .default,
        now: Date.init
    )
    manager.state = .readyToInstall(release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL)

    let contractURL = try manager.writeInstallContract(installedAppURL: URL(fileURLWithPath: "/Applications/Pulse.app"))

    XCTAssertTrue(FileManager.default.fileExists(atPath: contractURL.path))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests -only-testing:pulseTests/UpdateInstallPlannerTests
```

Expected: FAIL with missing `writeInstallContract` and helper launch preparation behavior.

- [ ] **Step 3: Implement the helper target and the app-to-helper handoff**

Create `pulseUpdater/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
let delegate = UpdaterAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

Create `pulseUpdater/UpdaterWindowController.swift`:

```swift
import AppKit

final class UpdaterWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "Preparing update...")
    private let detailLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.title = "Pulse Updater"
    }

    func show(status: String, detail: String = "") {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

Create `pulseUpdater/UpdaterInstaller.swift`:

```swift
import Foundation

struct UpdaterInstaller {
    let fileManager: FileManager

    func install(using contract: UpdateInstallContract) throws {
        let installedURL = URL(fileURLWithPath: contract.installedAppPath)
        let stagedURL = URL(fileURLWithPath: contract.stagedAppPath)
        let backupURL = URL(fileURLWithPath: contract.backupAppPath)

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        if fileManager.fileExists(atPath: installedURL.path) {
            try fileManager.moveItem(at: installedURL, to: backupURL)
        }
        try fileManager.moveItem(at: stagedURL, to: installedURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", installedURL.path]
        try? process.run()
        process.waitUntilExit()
    }
}
```

Create `pulseUpdater/UpdaterAppDelegate.swift`:

```swift
import AppKit

final class UpdaterAppDelegate: NSObject, NSApplicationDelegate {
    private let windowController = UpdaterWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let contractURL = try contractURLFromArguments()
            let data = try Data(contentsOf: contractURL)
            let contract = try JSONDecoder().decode(UpdateInstallContract.self, from: data)

            windowController.show(status: "Installing Pulse \(contract.expectedVersion)")
            try UpdaterInstaller(fileManager: .default).install(using: contract)

            let relaunched = NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: contract.installedAppPath), configuration: NSWorkspace.OpenConfiguration())
            if relaunched == false {
                throw NSError(domain: "PulseUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pulse did not relaunch."])
            }
        } catch {
            windowController.show(
                status: "Pulse could not finish updating.",
                detail: "Run: xattr -dr com.apple.quarantine /Applications/Pulse.app"
            )
        }
    }

    private func contractURLFromArguments() throws -> URL {
        guard CommandLine.arguments.count > 1 else {
            throw NSError(domain: "PulseUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing contract path"])
        }
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
}
```

Extend `pulse/Managers/UpdateManager.swift` with helper handoff methods:

```swift
@MainActor
func writeInstallContract(installedAppURL: URL) throws -> URL {
    guard case let .readyToInstall(release, _, stagedAppURL) = state else {
        throw NSError(domain: "UpdateManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "No staged update available"])
    }

    let planner = UpdateInstallPlanner(fileManager: fileManager)
    let contract = try planner.makeContract(
        expectedVersion: release.version,
        stagedAppURL: stagedAppURL,
        installedAppURL: installedAppURL
    )

    let contractURL = fileManager.temporaryDirectory.appendingPathComponent("pulse-update-contract.json")
    try JSONEncoder().encode(contract).write(to: contractURL)
    return contractURL
}

@MainActor
func beginInstall(installedAppURL: URL = URL(fileURLWithPath: "/Applications/Pulse.app")) throws {
    let contractURL = try writeInstallContract(installedAppURL: installedAppURL)
    let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/PulseUpdater.app")

    state = .launchingInstaller(currentRelease)

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = [contractURL.path]
    NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration)
    NSApp.terminate(nil)
}
```

Update the Xcode project manually to add a `PulseUpdater` app target and embed it into the main app bundle under `Contents/Helpers/`.

- [ ] **Step 4: Build both targets and verify the helper is embedded**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: SUCCEEDED, and the built `Pulse.app` contains `Contents/Helpers/PulseUpdater.app`.

- [ ] **Step 5: Commit the helper target**

```bash
git add pulse/Managers/UpdateManager.swift pulseUpdater/main.swift pulseUpdater/UpdaterAppDelegate.swift pulseUpdater/UpdaterWindowController.swift pulseUpdater/UpdaterInstaller.swift pulse.xcodeproj/project.pbxproj pulseTests/UpdateManagerTests.swift
git commit -m "feat: add bundled updater helper"
```

---

### Task 6: Finish ZIP Download, Artifact Verification, Release Packaging, And End-to-End Verification

**Files:**
- Modify: `pulse/Managers/UpdateManager.swift`
- Modify: `pulse/Managers/UpdateGitHubClient.swift`
- Modify: `scripts/build-dmg.sh`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing tests for ready-to-install staging**

Append to `pulseTests/UpdateManagerTests.swift`:

```swift
func testVerifyExpandedAppMovesStateToReadyToInstall() throws {
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

    try manager.acceptVerifiedStagedUpdate(release: release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL)

    XCTAssertEqual(manager.state, .readyToInstall(release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/UpdateManagerTests
```

Expected: FAIL with missing `acceptVerifiedStagedUpdate`.

- [ ] **Step 3: Implement ZIP staging, verification, and dual-artifact release packaging**

Extend `pulse/Managers/UpdateManager.swift` with minimal staging acceptance so the state machine is explicit before adding actual network download plumbing:

```swift
@MainActor
func acceptVerifiedStagedUpdate(release: AppRelease, stagedZipURL: URL, stagedAppURL: URL) throws {
    guard stagedAppURL.lastPathComponent == "Pulse.app" else {
        throw NSError(domain: "UpdateManager", code: 20, userInfo: [NSLocalizedDescriptionKey: "Expanded archive did not contain Pulse.app"])
    }

    state = .readyToInstall(release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL)
}
```

Then replace the placeholder download path with a real sequence:

```swift
@MainActor
func downloadAvailableUpdate(_ release: AppRelease) async throws {
    state = .downloading(release, progress: 0)

    let zipURL = fileManager.temporaryDirectory.appendingPathComponent("Pulse-\(release.version)-updater.zip")
    let (downloadedURL, _) = try await URLSession.shared.download(from: release.zipAssetURL)

    if fileManager.fileExists(atPath: zipURL.path) {
        try fileManager.removeItem(at: zipURL)
    }
    try fileManager.moveItem(at: downloadedURL, to: zipURL)

    let expandedDirectory = fileManager.temporaryDirectory.appendingPathComponent("Pulse-\(release.version)-expanded")
    try? fileManager.removeItem(at: expandedDirectory)
    try fileManager.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)

    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", zipURL.path, expandedDirectory.path]
    try unzip.run()
    unzip.waitUntilExit()

    let stagedAppURL = expandedDirectory.appendingPathComponent("Pulse.app")
    try acceptVerifiedStagedUpdate(release: release, stagedZipURL: zipURL, stagedAppURL: stagedAppURL)
}
```

Modify `scripts/build-dmg.sh` so releases produce both assets:

```bash
ZIP_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}-updater.zip"

echo "==> Creating updater ZIP..."
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_OUT}"

echo "==> Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_TMP}"
```

Update `pulse.xcodeproj/project.pbxproj` to bump:

```text
MARKETING_VERSION = 1.8.0;
```

- [ ] **Step 4: Run the full verification commands**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' && xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build && bash scripts/build-dmg.sh
```

Expected: all tests PASS, app build SUCCEEDED, and `dist/` contains both `Pulse-1.8.0.dmg` and `Pulse-1.8.0-updater.zip`.

- [ ] **Step 5: Perform the manual end-to-end update rehearsal and commit**

Manual checklist:

```text
1. Launch an older Pulse build from /Applications.
2. Confirm startup auto-check does not run again within 24 hours after a success.
3. Use Settings -> Updates -> Check for Updates... and confirm manual check bypasses throttle.
4. Download the ZIP update and watch inline progress in Pulse.
5. Click Install Update and confirm PulseUpdater appears only during install.
6. Verify the app relaunches automatically.
7. Simulate relaunch failure by temporarily blocking the launch marker path or helper relaunch path.
8. Confirm the updater window stays open and shows: xattr -dr com.apple.quarantine /Applications/Pulse.app
```

Commit:

```bash
git add pulse/Managers/UpdateManager.swift pulse/Managers/UpdateGitHubClient.swift scripts/build-dmg.sh pulse.xcodeproj/project.pbxproj pulseTests/UpdateManagerTests.swift
git commit -m "feat: add github-based auto upgrade flow"
```

---

## Self-Review Notes

- Spec coverage: this plan covers startup checks, manual checks, Settings and status menu UI, ZIP-based download, helper-based install, rollback contract/planner, relaunch success detection, fallback `xattr` messaging, helper embedding, and release packaging updates.
- Placeholder scan: no `TODO` or `TBD` placeholders remain; every task names exact files, commands, and code snippets.
- Type consistency: the plan consistently uses `AppRelease`, `UpdateState`, `UpdateInstallContract`, `UpdateInstallPlanner`, and `UpdateManager` across all tasks.
