# Keep Awake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Keep Awake feature to Pulse with two modes: Smart (agent-aware auto-sleep prevention) and Manual (force-on with optional timer).

**Architecture:** New `KeepAwakeSettings` manager owns `IOPMAssertion` lifecycle. In Manual mode, assertion is held until timer expires or user disables. In Smart mode, assertion is created when any agent slot enters `.working` and released after all slots are idle for 5 minutes. Status bar icon swaps between `cpu` and `cpu.fill` to indicate active state.

**Tech Stack:** Swift, IOKit (IOPMAssertion), Combine, AppKit (NSMenu, NSStatusItem), UserDefaults

**Spec:** `docs/superpowers/specs/2026-08-20-keep-awake-design.md`

## Global Constraints

- macOS 14+ target (LSUIElement menu bar app, no Dock icon)
- No external dependencies — only Apple frameworks
- Semantic colors from `pulse/Views/Colors.swift`
- Follow existing `LaunchAtLoginSettings` pattern for the new settings manager
- All reads of `UserDefaults` use string keys prefixed with `general.keepAwake.`
- Xcode project file must be updated for new source files

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `pulse/Managers/KeepAwakeSettings.swift` | Create | Settings store, IOPMAssertion lifecycle, smart mode monitoring, timer |
| `pulse/App/AppDelegate.swift` | Modify | Instantiate store, icon swap, context menu item, inject into Settings |
| `pulse/Views/SettingsView.swift` | Modify | Add Keep Awake section to General tab |
| `pulseTests/KeepAwakeSettingsTests.swift` | Create | Unit tests for KeepAwakeSettings |
| `pulse.xcodeproj/project.pbxproj` | Modify | Register new files |

---

### Task 1: Create KeepAwakeSettings store with Manual mode

**Files:**
- Create: `pulse/Managers/KeepAwakeSettings.swift`
- Test: `pulseTests/KeepAwakeSettingsTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UserDefaults` (injected, `.standard` default)
- Produces: `KeepAwakeSettings` class with `@Published var mode`, `@Published var displaySleepOnly`, `@Published var timerDuration`, `@Published private(set) var isActive`, computed `isSmartAvailable`, method `setEnabled(_ enabled: Bool)`, `restoreIfNeeded()`, `deactivate()`

- [ ] **Step 1: Create the test file**

```swift
// pulseTests/KeepAwakeSettingsTests.swift
import XCTest
@testable import pulse

@MainActor
final class KeepAwakeSettingsTests: XCTestCase {
    private func makeSut(
        defaults: UserDefaults = .init(suiteName: "KeepAwakeSettingsTests")!
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/KeepAwakeSettingsTests 2>&1 | tail -20`
Expected: FAIL — `KeepAwakeSettings` type does not exist

- [ ] **Step 3: Create KeepAwakeSettings.swift with Manual mode**

```swift
// pulse/Managers/KeepAwakeSettings.swift
import Combine
import Foundation
import IOKit

@MainActor
final class KeepAwakeSettings: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable, Codable {
        case smart, manual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .smart: return "Smart"
            case .manual: return "Manual"
            }
        }
    }

    enum TimerDuration: String, CaseIterable, Identifiable, Codable {
        case indefinite, m30, h1, h2, h5
        var id: String { rawValue }
        var label: String {
            switch self {
            case .indefinite: return "Indefinite"
            case .m30: return "30 min"
            case .h1: return "1 hr"
            case .h2: return "2 hr"
            case .h5: return "5 hr"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .indefinite: return nil
            case .m30: return 30 * 60
            case .h1: return 60 * 60
            case .h2: return 2 * 60 * 60
            case .h5: return 5 * 60 * 60
            }
        }
    }

    private enum Keys {
        static let mode = "general.keepAwake.mode"
        static let displaySleepOnly = "general.keepAwake.displaySleepOnly"
        static let timerDuration = "general.keepAwake.timerDuration"
        static let isActive = "general.keepAwake.isActive"
        static let timerEndDate = "general.keepAwake.timerEndDate"
    }

    @Published var mode: Mode {
        didSet {
            userDefaults.set(mode.rawValue, forKey: Keys.mode)
            apply()
        }
    }

    @Published var displaySleepOnly: Bool {
        didSet {
            userDefaults.set(displaySleepOnly, forKey: Keys.displaySleepOnly)
            if isActive {
                releaseAssertion()
                createAssertion()
            }
        }
    }

    @Published var timerDuration: TimerDuration {
        didSet {
            userDefaults.set(timerDuration.rawValue, forKey: Keys.timerDuration)
            if isActive {
                cancelTimer()
                scheduleTimerIfNeeded()
            }
        }
    }

    @Published private(set) var isActive: Bool {
        didSet {
            userDefaults.set(isActive, forKey: Keys.isActive)
            onIsActiveChange?(isActive)
        }
    }

    var isSmartAvailable: Bool {
        agentLightsEnabled && hasInstalledAgent
    }

    var onIsActiveChange: ((Bool) -> Void)?

    private let userDefaults: UserDefaults
    private let agentLightsEnabled: () -> Bool
    private let installedAgentCheck: () -> Bool

    private var assertionID: IOPMAssertionID = 0
    private var timerWorkItem: DispatchWorkItem?

    init(
        userDefaults: UserDefaults = .standard,
        agentLightsEnabled: @escaping () -> Bool = { false },
        hasInstalledAgent: @escaping () -> Bool = { false }
    ) {
        self.userDefaults = userDefaults
        self.agentLightsEnabled = agentLightsEnabled
        self.installedAgentCheck = hasInstalledAgent

        let savedMode = Mode(rawValue: userDefaults.string(forKey: Keys.mode) ?? "") ?? .manual
        self.mode = savedMode
        self.displaySleepOnly = userDefaults.bool(forKey: Keys.displaySleepOnly)
        let savedDuration = TimerDuration(rawValue: userDefaults.string(forKey: Keys.timerDuration) ?? "") ?? .indefinite
        self.timerDuration = savedDuration
        self.isActive = userDefaults.bool(forKey: Keys.isActive)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            activate()
        } else {
            deactivate()
        }
    }

    func restoreIfNeeded() {
        guard isActive else { return }
        if mode == .manual {
            createAssertion()
            scheduleTimerIfNeeded()
        }
        // Smart mode re-enters monitoring via observation setup in AppDelegate
    }

    func deactivate() {
        cancelTimer()
        releaseAssertion()
        isActive = false
    }

    // MARK: - Private

    private func apply() {
        // Called when mode or displaySleepOnly changes while active
        if isActive {
            releaseAssertion()
            if mode == .manual {
                createAssertion()
                cancelTimer()
                scheduleTimerIfNeeded()
            }
        }
    }

    private func activate() {
        cancelTimer()
        releaseAssertion()
        createAssertion()
        isActive = true
        scheduleTimerIfNeeded()
    }

    private func createAssertion() {
        let type: String
        if displaySleepOnly {
            type = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        } else {
            type = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        }

        let reason = "Pulse Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result != kIOReturnSuccess {
            assertionID = 0
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    private func scheduleTimerIfNeeded() {
        guard let interval = timerDuration.interval else { return }
        let endDate = Date().addingTimeInterval(interval)
        userDefaults.set(endDate.timeIntervalSince1970, forKey: Keys.timerEndDate)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.deactivate()
            }
        }
        timerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func cancelTimer() {
        timerWorkItem?.cancel()
        timerWorkItem = nil
        userDefaults.removeObject(forKey: Keys.timerEndDate)
    }
}
```

- [ ] **Step 4: Register new files in Xcode project**

Run: `ruby scripts/add_files.rb pulse/Managers/KeepAwakeSettings.swift pulseTests/KeepAwakeSettingsTests.swift`
(Or manually add both files to the `pulse` and `pulseTests` targets in `pulse.xcodeproj/project.pbxproj`.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/KeepAwakeSettingsTests 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/KeepAwakeSettings.swift pulseTests/KeepAwakeSettingsTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat(keep-awake): add KeepAwakeSettings store with manual mode"
```

---

### Task 2: Add Smart mode monitoring

**Files:**
- Modify: `pulse/Managers/KeepAwakeSettings.swift`
- Modify: `pulseTests/KeepAwakeSettingsTests.swift`

**Interfaces:**
- Consumes: `AgentStatusStore.$groups` (Combine publisher), `agentLightsEnabled` closure, `installedAgentCheck` closure
- Produces: `startSmartMonitoring()`, `stopSmartMonitoring()` methods; assertion auto-created on `.working`, auto-released after 5-minute idle cooldown

- [ ] **Step 1: Add smart mode tests**

Append to `pulseTests/KeepAwakeSettingsTests.swift`:

```swift
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
        sut.mode = .smart
        // Should fall back to manual since smart is not available
        XCTAssertEqual(sut.mode, .manual)
    }
```

- [ ] **Step 2: Run new tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/KeepAwakeSettingsTests/test_smartMode_isSmartAvailable_trueWhenAgentLightsEnabledAndInstalled 2>&1 | tail -10`
Expected: FAIL — `isSmartAvailable` not yet implemented

- [ ] **Step 3: Add smart mode properties and monitoring to KeepAwakeSettings**

Add to `KeepAwakeSettings.swift`:

```swift
    // Add new properties inside the class, after existing properties:
    private let idleCooldown: TimeInterval = 300 // 5 minutes
    private var smartIdleWorkItem: DispatchWorkItem?
    private var groupsObservation: AnyCancellable?
    private var isSmartAsserted = false
```

Add new methods:

```swift
    func startSmartMonitoring(store: AgentStatusStore) {
        stopSmartMonitoring()
        groupsObservation = store.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] groups in
                self?.handleAgentGroups(groups)
            }
    }

    func stopSmartMonitoring() {
        groupsObservation?.cancel()
        groupsObservation = nil
        smartIdleWorkItem?.cancel()
        smartIdleWorkItem = nil
        if isSmartAsserted {
            releaseAssertion()
            isSmartAsserted = false
        }
    }

    private func handleAgentGroups(_ groups: [AgentStatusGroup]) {
        guard mode == .smart else { return }

        let hasWorking = groups.flatMap(\.slots).contains { $0.state == .working }

        if hasWorking {
            // Cancel any pending idle timer
            smartIdleWorkItem?.cancel()
            smartIdleWorkItem = nil

            // Assert if not already asserted
            if !isSmartAsserted {
                createAssertion()
                isSmartAsserted = true
                isActive = true
            }
        } else if isSmartAsserted {
            // All idle — start cooldown if not already started
            if smartIdleWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.releaseAssertion()
                        self?.isSmartAsserted = false
                        self?.isActive = false
                        self?.smartIdleWorkItem = nil
                    }
                }
                smartIdleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + idleCooldown, execute: work)
            }
        }
    }
```

Also update `deactivate()` to stop smart monitoring:

```swift
    func deactivate() {
        cancelTimer()
        stopSmartMonitoring()
        releaseAssertion()
        isSmartAsserted = false
        isActive = false
    }
```

And update `restoreIfNeeded()`:

```swift
    func restoreIfNeeded() {
        guard isActive else { return }
        if mode == .manual {
            createAssertion()
            scheduleTimerIfNeeded()
        }
        // Smart mode: observation will be started by AppDelegate
    }
```

- [ ] **Step 4: Run all tests**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/KeepAwakeSettingsTests 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/KeepAwakeSettings.swift pulseTests/KeepAwakeSettingsTests.swift
git commit -m "feat(keep-awake): add smart mode agent monitoring with 5-min idle cooldown"
```

---

### Task 3: Wire into AppDelegate — icon swap, context menu, smart monitoring

**Files:**
- Modify: `pulse/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `KeepAwakeSettings` (from Task 1-2), `AgentStatusStore`, `AgentLightsSettings`, `AgentIntegrationManager` (all existing)
- Produces: Status bar icon updates, context menu "Keep Awake" item, smart monitoring startup

- [ ] **Step 1: Add the keepAwakeSettings property**

In `AppDelegate.swift`, after the `launchAtLoginSettings` property (line 97), add:

```swift
    private lazy var keepAwakeSettings = KeepAwakeSettings(
        agentLightsEnabled: { [weak self] in self?.agentLightsSettings.isEnabled ?? false },
        hasInstalledAgent: { [weak self] in
            guard let self else { return false }
            return agentIntegrationManager.status(for: .openCode).state == .installedNeedsRestart
                || agentIntegrationManager.status(for: .openCode).state == .installedNeedsActivation
                || agentIntegrationManager.status(for: .codex).state == .installedNeedsRestart
                || agentIntegrationManager.status(for: .codex).state == .installedNeedsActivation
        }
    )
```

- [ ] **Step 2: Add icon swap observation**

In `setupFeatureObservation()`, append a new Combine subscription after the existing `agentLightsSettings` observation:

```swift
        keepAwakeSettings.onIsActiveChange = { [weak self] isActive in
            guard let button = self?.statusItem.button else { return }
            let symbolName = isActive ? "cpu.fill" : "cpu"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "System Monitor")
            button.image?.isTemplate = true
        }
```

- [ ] **Step 3: Add restoreIfNeeded() call on launch**

In `applicationDidFinishLaunching`, after `setupStatusItem()` (line 119), add:

```swift
        keepAwakeSettings.restoreIfNeeded()
```

- [ ] **Step 4: Add smart monitoring startup**

In `setupFeatureObservation()`, add observation of agent lights changes to start/stop smart monitoring:

```swift
        agentLightsSettings.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled && keepAwakeSettings.mode == .smart {
                    keepAwakeSettings.startSmartMonitoring(store: agentStatusStore)
                } else {
                    keepAwakeSettings.stopSmartMonitoring()
                }
            }
            .store(in: &cancellables)
```

- [ ] **Step 5: Add context menu item**

In `showContextMenu()`, insert a "Keep Awake" menu item between the "Settings..." item and the separator:

```swift
    private func showContextMenu() {
        let menu = NSMenu()
        let openTitle = (panel?.isVisible == true) ? "Close" : "Open"
        let openItem = NSMenuItem(title: openTitle, action: #selector(togglePanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let keepAwakeItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwakeItem.target = self
        keepAwakeItem.state = keepAwakeSettings.isActive ? .on : .off
        menu.addItem(keepAwakeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
```

- [ ] **Step 6: Add the toggleKeepAwake selector**

Add a new method in `AppDelegate.swift`:

```swift
    @objc private func toggleKeepAwake() {
        keepAwakeSettings.setEnabled(!keepAwakeSettings.isActive)
        if keepAwakeSettings.mode == .smart && keepAwakeSettings.isActive {
            keepAwakeSettings.startSmartMonitoring(store: agentStatusStore)
        }
    }
```

- [ ] **Step 7: Build and verify no compile errors**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add pulse/App/AppDelegate.swift
git commit -m "feat(keep-awake): wire into AppDelegate with icon swap and context menu"
```

---

### Task 4: Add Keep Awake section to SettingsView

**Files:**
- Modify: `pulse/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `KeepAwakeSettings` (from Task 1-2), `AgentLightsSettings` (existing)
- Produces: Keep Awake section in General settings with mode picker, display-sleep toggle, timer picker, smart status line

- [ ] **Step 1: Add @EnvironmentObject declaration**

In `SettingsView.swift`, add after the `launchAtLoginSettings` environment object (line 9):

```swift
    @EnvironmentObject var keepAwakeSettings: KeepAwakeSettings
```

- [ ] **Step 2: Add the Keep Awake section to generalContent**

In `generalContent`, append after the Theme picker block (after line 128, before the closing `}`):

```swift
            Divider()

            Text("Keep Awake")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Prevent your Mac from going to sleep.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $keepAwakeSettings.mode) {
                ForEach(KeepAwakeSettings.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .disabled(keepAwakeSettings.mode == .smart && !keepAwakeSettings.isSmartAvailable)

            if keepAwakeSettings.mode == .smart && !keepAwakeSettings.isSmartAvailable {
                Text("Smart mode requires Agent Lights to be enabled with at least one agent installed.")
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Allow display to sleep", isOn: $keepAwakeSettings.displaySleepOnly)
                .toggleStyle(.switch)

            Text("Keep system awake but allow the screen to dim.")
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if keepAwakeSettings.mode == .manual {
                Picker("Timer", selection: $keepAwakeSettings.timerDuration) {
                    ForEach(KeepAwakeSettings.TimerDuration.allCases) { duration in
                        Text(duration.label).tag(duration)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
            }

            if keepAwakeSettings.mode == .smart && keepAwakeSettings.isActive {
                Text("Monitoring agents...")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else if keepAwakeSettings.mode == .smart && !keepAwakeSettings.isActive {
                Text("Waiting for agent activity...")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            }
```

- [ ] **Step 3: Inject the environment object in AppDelegate**

In `AppDelegate.swift`, in the `makeSettingsWindow()` method, add `.environmentObject(keepAwakeSettings)` to the chain:

```swift
        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(themeManager)
                .environmentObject(agentUsageSettings)
                .environmentObject(agentLightsSettings)
                .environmentObject(agentStatusStore)
                .environmentObject(updateManager)
                .environmentObject(launchAtLoginSettings)
                .environmentObject(keepAwakeSettings)
        )
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add pulse/Views/SettingsView.swift pulse/App/AppDelegate.swift
git commit -m "feat(keep-awake): add Keep Awake section to Settings General tab"
```

---

### Task 5: Run full test suite and verify

**Files:**
- No new files (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' 2>&1 | tail -30`
Expected: ALL TESTS PASS

- [ ] **Step 2: Run lint/typecheck if available**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E 'error:|warning:'`
Expected: No new errors or warnings

- [ ] **Step 3: Manual smoke test checklist**

1. Build and run the app
2. Right-click the status bar icon → "Keep Awake" should appear with no checkmark
3. Click "Keep Awake" → icon should change to `cpu.fill`, checkmark should appear
4. Click "Keep Awake" again → icon reverts to `cpu`, checkmark disappears
5. Open Settings → General → Keep Awake section should appear below Theme
6. Toggle mode to Smart → timer picker should disappear
7. Toggle mode to Manual → timer picker should appear
8. Toggle "Allow display to sleep" → should toggle without errors
9. Select a timer duration → after that duration, Keep Awake should auto-disable

- [ ] **Step 4: Final commit (if any fixes needed)**

```bash
git add -A
git commit -m "fix(keep-awake): address review feedback"
```
