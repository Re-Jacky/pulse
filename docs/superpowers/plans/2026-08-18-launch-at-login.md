# Launch at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Launch at Login" toggle in a new General Settings section that registers Pulse as a macOS login item via `SMAppService.mainApp`.

**Architecture:** A new `LaunchAtLoginSettings` ObservableObject store (mirroring `AgentLightsSettings`) wraps `SMAppService.mainApp` behind an injectable `LaunchAtLoginService` protocol. The store is owned by `AppDelegate`, injected into `SettingsView`, and re-syncs from real system status whenever Settings opens. The Settings sidebar gains a General section that absorbs the existing Theme picker and adds the toggle.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, ServiceManagement (`SMAppService.mainApp`, macOS 13+; app targets macOS 14+), XCTest.

## Global Constraints

- Target macOS 14+. `SMAppService` (import `ServiceManagement`) is available — do NOT use `SMLoginItemSetEnabled` or LaunchAgent plists.
- No new external dependencies — only Apple frameworks.
- Semantic colors from `pulse/Views/Colors.swift` (`.appPrimaryText`, `.appSecondaryText`); no hard-coded light/dark values.
- Do not introduce `@StateObject` into views that receive environment objects from `AppDelegate`.
- The live `SMAppService.mainApp.status` is the source of truth; `UserDefaults` key `general.launchAtLogin` stores the last intent.
- New Swift files must be registered in `pulse.xcodeproj/project.pbxproj`: use `ruby add_files.rb` for the manager file (it adds to `targets.first` = `pulse`), and edit the pbxproj **manually** for the test file (add_files.rb would add it to the `pulse` app target, which is wrong — tests belong in `pulseTests`).
- Commands: build = `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`; tests = `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`.

---

### Task 1: LaunchAtLoginSettings store + service protocol + tests

**Files:**
- Create: `pulse/Managers/LaunchAtLoginSettings.swift`
- Create: `pulseTests/LaunchAtLoginSettingsTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj` (register both files)

**Interfaces:**
- Produces:
  - `protocol LaunchAtLoginService { var isEnabled: Bool { get }; func register() throws; func unregister() throws }`
  - `struct SMAppServiceLaunchAtLoginService: LaunchAtLoginService` (wraps `SMAppService.mainApp`; `isEnabled` is `SMAppService.mainApp.status == .enabled`)
  - `final class LaunchAtLoginSettings: ObservableObject` with `init(service: LaunchAtLoginService = SMAppServiceLaunchAtLoginService(), userDefaults: UserDefaults = .standard)`, `@Published private(set) var isEnabled: Bool`, `@Published private(set) var errorMessage: String?`, `func setEnabled(_ enabled: Bool)`, `func refresh()`, and `static let userDefaultsKey = "general.launchAtLogin"`.

- [ ] **Step 1: Write the failing store skeleton (so tests compile)**

Create `pulse/Managers/LaunchAtLoginSettings.swift` with the types but WITHOUT the real service wiring — the setter only records intent, refresh only reads UserDefaults. This is the red-phase scaffold.

```swift
import Combine
import Foundation
import ServiceManagement

protocol LaunchAtLoginService {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

struct SMAppServiceLaunchAtLoginService: LaunchAtLoginService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

final class LaunchAtLoginSettings: ObservableObject {
    static let userDefaultsKey = "general.launchAtLogin"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: LaunchAtLoginService
    private let userDefaults: UserDefaults

    init(service: LaunchAtLoginService = SMAppServiceLaunchAtLoginService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
        isEnabled = userDefaults.object(forKey: Self.userDefaultsKey) as? Bool ?? false
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.userDefaultsKey)
    }

    func refresh() {
        isEnabled = userDefaults.object(forKey: Self.userDefaultsKey) as? Bool ?? false
    }
}
```

Register the manager file in the project:

```bash
ruby add_files.rb pulse/Managers/LaunchAtLoginSettings.swift
```

- [ ] **Step 2: Write the failing tests**

Create `pulseTests/LaunchAtLoginSettingsTests.swift`:

```swift
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
```

Register the test file in the pbxproj **manually** (do NOT use `add_files.rb`). Follow the existing `AgentUsageMappingStoreTests.swift` pattern. The IDs below are verified free (`rg "F1A4E2C9B3D8071[56]" pulse.xcodeproj/project.pbxproj` returns nothing) — use them exactly:

1. Add a `PBXBuildFile` entry in the `/* Begin PBXBuildFile section */` block:
   `F1A4E2C9B3D80715 /* LaunchAtLoginSettingsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1A4E2C9B3D80716 /* LaunchAtLoginSettingsTests.swift */; };`
2. Add a `PBXFileReference` in the `/* Begin PBXFileReference section */` block:
   `F1A4E2C9B3D80716 /* LaunchAtLoginSettingsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LaunchAtLoginSettingsTests.swift; sourceTree = "<group>"; };`
3. Add `F1A4E2C9B3D80716 /* LaunchAtLoginSettingsTests.swift */` to the `pulseTests` group's `children` list (the group containing the other `*Tests.swift` file references).
4. Add `F1A4E2C9B3D80715 /* LaunchAtLoginSettingsTests.swift in Sources */` to the `pulseTests` Sources build phase (`100000000000000000000009 /* Sources */`, the phase listing the other `*Tests.swift in Sources` entries).

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
Expected: `LaunchAtLoginSettingsTests` FAIL — e.g. `testEnableCallsRegisterAndPersists` fails because the skeleton `setEnabled` never calls `service.register()` (registerCallCount is 0), and `testRefreshSyncsFromServiceStatusAndClearsError` fails because refresh reads UserDefaults instead of the service status.

- [ ] **Step 4: Implement the real behavior**

Replace the body of `setEnabled` and `refresh` in `pulse/Managers/LaunchAtLoginSettings.swift`:

```swift
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            isEnabled = enabled
            userDefaults.set(enabled, forKey: Self.userDefaultsKey)
            errorMessage = nil
        } catch {
            isEnabled = service.isEnabled
            errorMessage = "Pulse could not be updated in Login Items. Open System Settings > General > Login Items and add Pulse manually."
        }
    }

    func refresh() {
        isEnabled = service.isEnabled
        errorMessage = nil
    }
```

Also update the `init` so the initial state reflects the live service status rather than only UserDefaults:

```swift
    init(service: LaunchAtLoginService = SMAppServiceLaunchAtLoginService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
        isEnabled = service.isEnabled
        errorMessage = nil
    }
```

Note: the `init` now reads the live status, which keeps `testInitReadsLiveServiceStatusOverUserDefaults` green. `refresh()` re-reads the live status so Settings-open re-syncs work.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
Expected: `LaunchAtLoginSettingsTests` PASS (all 8 tests), and the rest of the suite still PASSES.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/LaunchAtLoginSettings.swift pulseTests/LaunchAtLoginSettingsTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add launch at login settings store"
```

---

### Task 2: General Settings section + AppDelegate wiring

**Files:**
- Modify: `pulse/Views/SettingsView.swift`
- Modify: `pulse/App/AppDelegate.swift`

**Interfaces:**
- Consumes from Task 1: `LaunchAtLoginSettings` with `@Published private(set) var isEnabled`, `@Published private(set) var errorMessage`, `func setEnabled(_:)`, `func refresh()`, `static let userDefaultsKey`.
- Produces: `SettingsView` gains `@EnvironmentObject var launchAtLoginSettings: LaunchAtLoginSettings` and a `Section.general` sidebar item; `AppDelegate` gains `private let launchAtLoginSettings = LaunchAtLoginSettings()`, injects it into `SettingsView`, and calls `launchAtLoginSettings.refresh()` on launch and on Settings open.

- [ ] **Step 1: Add the toggle + General section to SettingsView**

Edit `pulse/Views/SettingsView.swift`:

1. Add the environment object at the top of the struct (after line 5, `@EnvironmentObject var agentUsageSettings: AgentUsageSettings;`):

```swift
    @EnvironmentObject var launchAtLoginSettings: LaunchAtLoginSettings
```

2. Rename the sidebar section and add the General button. Replace the `Section` enum:

```swift
    private enum Section: Hashable {
        case general
        case agentUsage
        case agentLights
        case updates
    }
```

Replace the sidebar buttons block (currently lines 26-29):

```swift
                sidebarButton(title: "General", systemImage: "gearshape", section: .general)
                sidebarButton(title: "Agent Usage", systemImage: "person.2.wave.2", section: .agentUsage)
                sidebarButton(title: "Agent Lights", systemImage: "dot.radiowaves.left.and.right", section: .agentLights)
                sidebarButton(title: "Updates", systemImage: "arrow.triangle.2.circlepath", section: .updates)
```

3. Update the content switch to route `.general`:

```swift
                            switch selectedSection {
                            case .general:
                                generalContent
                            case .agentUsage:
                                agentUsageContent
                            case .agentLights:
                                agentLightsContent
                            case .updates:
                                updateContent
                            }
```

4. Replace the current `themeContent` computed property with a new `generalContent` that leads with the Launch at Login toggle and error line, then the existing Theme picker:

```swift
    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)

                Text("Start Pulse automatically when you log in to your Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = launchAtLoginSettings.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }

            Divider()

            Text("Theme")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Choose whether Pulse follows the system appearance or always uses a specific theme.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Theme", selection: $themeManager.currentTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }
```

5. Add the binding helper at the bottom of the struct (next to `sourceBinding(for:)`):

```swift
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                launchAtLoginSettings.isEnabled
            },
            set: {
                launchAtLoginSettings.setEnabled($0)
            }
        )
    }
```

- [ ] **Step 2: Wire the store into AppDelegate**

Edit `pulse/App/AppDelegate.swift`:

1. Add the store property next to the other settings stores (near line 95, after `agentStatusStore`):

```swift
    private let launchAtLoginSettings = LaunchAtLoginSettings()
```

2. In `applicationDidFinishLaunching` (line 101-123), add a refresh line after `setupFeatureObservation()`:

```swift
        launchAtLoginSettings.refresh()
```

3. In `showSettings()` (line 613), add a refresh at the top so the toggle reflects any changes made in System Settings while Pulse is running:

```swift
        launchAtLoginSettings.refresh()
```

4. In `makeSettingsWindow()` (line 703-710), inject the store into `SettingsView`:

```swift
        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(themeManager)
                .environmentObject(agentUsageSettings)
                .environmentObject(agentLightsSettings)
                .environmentObject(agentStatusStore)
                .environmentObject(updateManager)
                .environmentObject(launchAtLoginSettings)
        )
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
Expected: ALL tests PASS, including `LaunchAtLoginSettingsTests`.

- [ ] **Step 4: Manual smoke check (optional but recommended)**

Run the app from the build products (`build/` or `DerivedData`), open Settings, verify the General section shows the Launch at Login toggle, and that toggling it on registers Pulse in System Settings → General → Login Items.

- [ ] **Step 5: Commit**

```bash
git add pulse/Views/SettingsView.swift pulse/App/AppDelegate.swift
git commit -m "feat: add launch at login toggle to General settings"
```