# Agent Status Integration Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add install, reinstall, recheck, uninstall, and activation guidance for OpenCode and Codex Agent Lights integrations directly in the standalone Agent Lights panel.

**Architecture:** Keep the existing live-event receiver and slot store unchanged, then layer a new integration-management subsystem on top. Pulse will own one shared local sender plus thin OpenCode and Codex adapter installers, and the Agent Lights panel will render install state separately from session light state.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Combine, Foundation, XCTest, local file generation under the user home directory.

---

## File Structure

- Create: `pulse/Managers/AgentIntegrationModels.swift`
  Defines install status, action availability, guidance copy, and the UI-facing integration card model.
- Create: `pulse/Managers/AgentIntegrationManager.swift`
  Owns detection, install, reinstall, uninstall, and recheck flows for OpenCode and Codex.
- Create: `pulse/Managers/OpenCodeIntegrationInstaller.swift`
  Generates and removes the Pulse-managed OpenCode plugin files.
- Create: `pulse/Managers/CodexIntegrationInstaller.swift`
  Generates and removes the Pulse-managed Codex hook files and config fragments.
- Create: `pulse/Managers/PulseAgentEventSenderTemplate.swift`
  Holds the shared sender script template and version marker content.
- Create: `pulseTests/AgentIntegrationManagerTests.swift`
  Covers detection, install state transitions, reinstall, uninstall, and file ownership safety.
- Modify: `pulse/Views/AgentStatusManagementView.swift`
  Add per-agent integration cards above the session rows.
- Modify: `pulse/App/AppDelegate.swift`
  Construct and inject the integration manager into the Agent Lights panel and settings window if needed.
- Modify: `pulse/Views/SettingsView.swift`
  Optionally add a short setup note that points users to the Agent Lights panel for install actions.
- Modify: `pulse.xcodeproj/project.pbxproj`
  Add the new source and test files to the Xcode project.

### Task 1: Add integration models and failing detection tests

**Files:**
- Create: `pulse/Managers/AgentIntegrationModels.swift`
- Create: `pulseTests/AgentIntegrationManagerTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests for initial integration state detection**

```swift
import Foundation
import XCTest
@testable import Pulse

final class AgentIntegrationManagerTests: XCTestCase {
    func testStatusesDefaultToNotInstalled() {
        let fs = InMemoryAgentIntegrationFileSystem()
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .openCode).state, .notInstalled)
        XCTAssertEqual(manager.status(for: .codex).state, .notInstalled)
    }

    func testCodexInstalledStateRequiresActivationGuidance() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .codexInstalled)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .codex).state, .installedNeedsActivation)
        XCTAssertTrue(manager.status(for: .codex).guidance.contains("Run /hooks."))
    }
}
```

- [ ] **Step 2: Run the new test file to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests`

Expected: FAIL with missing `AgentIntegrationManager`, `InMemoryAgentIntegrationFileSystem`, and install-state symbols.

- [ ] **Step 3: Add the integration model types**

```swift
import Foundation

enum AgentIntegrationState: Equatable {
    case notInstalled
    case installed
    case installedNeedsRestart
    case installedNeedsActivation
    case outdated
    case installFailed(String)
}

struct AgentIntegrationStatus: Equatable {
    let agent: AgentStatusAgent
    let state: AgentIntegrationState
    let primaryActionTitle: String
    let secondaryActions: [String]
    let guidance: [String]
}
```

- [ ] **Step 4: Add a minimal manager and in-memory file system fake to make the tests pass**

```swift
protocol AgentIntegrationFileSystem {
    func fileExists(at url: URL) -> Bool
    func readFile(at url: URL) -> String?
}

final class AgentIntegrationManager {
    private let fileSystem: AgentIntegrationFileSystem
    private let homeDirectoryURL: URL

    init(fileSystem: AgentIntegrationFileSystem, homeDirectoryURL: URL) {
        self.fileSystem = fileSystem
        self.homeDirectoryURL = homeDirectoryURL
    }

    func status(for agent: AgentStatusAgent) -> AgentIntegrationStatus {
        switch agent {
        case .openCode:
            return AgentIntegrationStatus(
                agent: agent,
                state: .notInstalled,
                primaryActionTitle: "Install Plugin",
                secondaryActions: [],
                guidance: []
            )
        case .codex:
            return AgentIntegrationStatus(
                agent: agent,
                state: .installedNeedsActivation,
                primaryActionTitle: "Install Hook",
                secondaryActions: ["Recheck", "Uninstall"],
                guidance: ["Open any Codex session.", "Run /hooks.", "Find the Pulse hook.", "Trust or enable it."]
            )
        }
    }
}
```

- [ ] **Step 5: Run the targeted tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests`

Expected: PASS for the two new tests.

- [ ] **Step 6: Commit the baseline integration model work**

```bash
git add pulse/Managers/AgentIntegrationModels.swift pulseTests/AgentIntegrationManagerTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent integration status models"
```

### Task 2: Build the shared sender template and installer generation

**Files:**
- Create: `pulse/Managers/PulseAgentEventSenderTemplate.swift`
- Create: `pulse/Managers/OpenCodeIntegrationInstaller.swift`
- Create: `pulse/Managers/CodexIntegrationInstaller.swift`
- Modify: `pulseTests/AgentIntegrationManagerTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing tests for generated plugin and hook payloads**

```swift
func testOpenCodeInstallerWritesPluginThatCallsSharedSender() throws {
    let fs = InMemoryAgentIntegrationFileSystem()
    let installer = OpenCodeIntegrationInstaller(fileSystem: fs, homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"))

    try installer.install()

    let plugin = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights.ts"))
    XCTAssertTrue(plugin.contains("session.idle"))
    XCTAssertTrue(plugin.contains("pulse-agent-event-sender"))
    XCTAssertTrue(plugin.contains("opencode"))
}

func testCodexInstallerWritesHookFilesWithPulseMarker() throws {
    let fs = InMemoryAgentIntegrationFileSystem()
    let installer = CodexIntegrationInstaller(fileSystem: fs, homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"))

    try installer.install()

    let hook = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights-hook.sh"))
    XCTAssertTrue(hook.contains("PULSE_MANAGED_VERSION"))
    XCTAssertTrue(hook.contains("codex"))
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests/testOpenCodeInstallerWritesPluginThatCallsSharedSender -only-testing:pulseTests/AgentIntegrationManagerTests/testCodexInstallerWritesHookFilesWithPulseMarker`

Expected: FAIL with missing installer types and helper methods.

- [ ] **Step 3: Add the shared sender template**

```swift
enum PulseAgentEventSenderTemplate {
    static let managedVersion = "pulse-agent-lights-v1"

    static func script(listenerPort: Int) -> String {
        """
        #!/bin/sh
        # PULSE_MANAGED_VERSION=\(managedVersion)
        node -e '
        const net = require("net");
        const payload = process.argv[1];
        const client = net.createConnection({ host: "127.0.0.1", port: \(listenerPort) }, () => {
          client.end(payload + "\\n");
        });
        client.on("error", () => process.exit(0));
        ' "$1"
        """
    }
}
```

- [ ] **Step 4: Implement the OpenCode and Codex installers with minimal file writing**

```swift
struct OpenCodeIntegrationInstaller {
    func install() throws {
        try fileSystem.writeFile(senderURL, contents: PulseAgentEventSenderTemplate.script(listenerPort: 45821))
        try fileSystem.writeFile(pluginURL, contents: pluginSource())
    }
}

struct CodexIntegrationInstaller {
    func install() throws {
        try fileSystem.writeFile(senderURL, contents: PulseAgentEventSenderTemplate.script(listenerPort: 45821))
        try fileSystem.writeFile(hookScriptURL, contents: hookScriptSource())
        try fileSystem.writeFile(hookConfigURL, contents: hookConfigSource())
    }
}
```

- [ ] **Step 5: Run the targeted tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests`

Expected: PASS for the new installer-generation tests and existing integration-model tests.

- [ ] **Step 6: Commit the installer generation work**

```bash
git add pulse/Managers/PulseAgentEventSenderTemplate.swift pulse/Managers/OpenCodeIntegrationInstaller.swift pulse/Managers/CodexIntegrationInstaller.swift pulseTests/AgentIntegrationManagerTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent integration installers"
```

### Task 3: Implement manager detection, reinstall, uninstall, and safety rules

**Files:**
- Modify: `pulse/Managers/AgentIntegrationManager.swift`
- Modify: `pulseTests/AgentIntegrationManagerTests.swift`

- [ ] **Step 1: Add failing tests for reinstall, uninstall, and outdated detection**

```swift
func testReinstallRewritesManagedFiles() throws {
    let fs = InMemoryAgentIntegrationFileSystem(seed: .openCodeInstalled)
    let manager = AgentIntegrationManager(fileSystem: fs, homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"))

    try manager.reinstall(.openCode)

    XCTAssertTrue(fs.didOverwriteManagedOpenCodePlugin)
}

func testUninstallPreservesNonPulseManagedFiles() throws {
    let fs = InMemoryAgentIntegrationFileSystem(seed: .userOwnedCodexHook)
    let manager = AgentIntegrationManager(fileSystem: fs, homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"))

    try manager.uninstall(.codex)

    XCTAssertTrue(fs.userOwnedCodexHookStillExists)
}

func testOutdatedStateIsReportedWhenManagedMarkerDoesNotMatch() {
    let fs = InMemoryAgentIntegrationFileSystem(seed: .outdatedOpenCodeInstall)
    let manager = AgentIntegrationManager(fileSystem: fs, homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"))

    XCTAssertEqual(manager.status(for: .openCode).state, .outdated)
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests`

Expected: FAIL for missing manager lifecycle methods and marker mismatch logic.

- [ ] **Step 3: Implement status detection from expected files and managed markers**

```swift
func status(for agent: AgentStatusAgent) -> AgentIntegrationStatus {
    let layout = layout(for: agent)
    guard fileSystem.fileExists(at: layout.primaryURL) else {
        return notInstalledStatus(for: agent)
    }

    guard let contents = fileSystem.readFile(at: layout.primaryURL),
          contents.contains(PulseAgentEventSenderTemplate.managedVersion) else {
        return outdatedStatus(for: agent)
    }

    return installedStatus(for: agent)
}
```

- [ ] **Step 4: Implement reinstall and uninstall using Pulse-managed ownership checks**

```swift
func reinstall(_ agent: AgentStatusAgent) throws {
    try uninstall(agent, managedFilesOnly: true)
    try install(agent)
}

func uninstall(_ agent: AgentStatusAgent, managedFilesOnly: Bool = true) throws {
    for url in managedURLs(for: agent) {
        guard let contents = fileSystem.readFile(at: url),
              contents.contains(PulseAgentEventSenderTemplate.managedVersion) else {
            continue
        }
        try fileSystem.removeItem(at: url)
    }
}
```

- [ ] **Step 5: Run the targeted tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests`

Expected: PASS for status, reinstall, uninstall, and ownership-safety scenarios.

- [ ] **Step 6: Commit the integration manager behavior**

```bash
git add pulse/Managers/AgentIntegrationManager.swift pulseTests/AgentIntegrationManagerTests.swift
git commit -m "feat: manage agent integration lifecycle"
```

### Task 4: Render integration cards in the Agent Lights panel

**Files:**
- Modify: `pulse/Views/AgentStatusManagementView.swift`
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulseTests/AgentLightsSettingsTests.swift`

- [ ] **Step 1: Add failing tests for the new UI guidance states**

```swift
func testOpenCodeStatusShowsRestartGuidance() {
    let status = AgentIntegrationStatus(
        agent: .openCode,
        state: .installedNeedsRestart,
        primaryActionTitle: "Reinstall",
        secondaryActions: ["Recheck", "Uninstall"],
        guidance: ["Restart OpenCode so the Pulse plugin is loaded."]
    )

    XCTAssertEqual(status.guidance.first, "Restart OpenCode so the Pulse plugin is loaded.")
}

func testCodexStatusShowsActivationGuidance() {
    let status = AgentIntegrationStatus(
        agent: .codex,
        state: .installedNeedsActivation,
        primaryActionTitle: "Reinstall",
        secondaryActions: ["Recheck", "Uninstall"],
        guidance: ["Open any Codex session.", "Run /hooks.", "Find the Pulse hook.", "Trust or enable it."]
    )

    XCTAssertTrue(status.guidance.contains("Run /hooks."))
}
```

- [ ] **Step 2: Run the focused tests to verify they fail if needed**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentLightsSettingsTests`

Expected: FAIL if the UI support types are not wired into the test target yet.

- [ ] **Step 3: Add the integration manager as an environment object to the Agent Lights panel**

```swift
private let agentIntegrationManager = AgentIntegrationManager()

let controller = NSHostingController(
    rootView: ZStack {
        VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
            .ignoresSafeArea()
        AgentStatusManagementView()
            .environmentObject(agentStatusStore)
            .environmentObject(agentIntegrationManager)
    }
    .id(themeManager.currentTheme)
)
```

- [ ] **Step 4: Render an integration card above each agent slot group**

```swift
@EnvironmentObject var agentIntegrationManager: AgentIntegrationManager

private func groupSection(_ group: AgentStatusGroup) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        integrationCard(for: agentIntegrationManager.status(for: group.agent))
        sessionsSection(group)
    }
}
```

- [ ] **Step 5: Wire button actions to install, reinstall, recheck, and uninstall**

```swift
Button(status.primaryActionTitle) {
    try? agentIntegrationManager.performPrimaryAction(for: status.agent)
}

ForEach(status.secondaryActions, id: \.self) { title in
    Button(title) {
        try? agentIntegrationManager.performSecondaryAction(title, for: status.agent)
    }
}
```

- [ ] **Step 6: Run the panel-related tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentLightsSettingsTests`

Expected: PASS, including the new guidance-state assertions plus existing menu-bar regression tests.

- [ ] **Step 7: Commit the Agent Lights panel UI update**

```bash
git add pulse/Views/AgentStatusManagementView.swift pulse/App/AppDelegate.swift pulseTests/AgentLightsSettingsTests.swift
git commit -m "feat: add agent integration controls to lights panel"
```

### Task 5: Final verification, polish, and documentation sync

**Files:**
- Modify: `pulse/Views/SettingsView.swift`
- Modify: `docs/superpowers/specs/2026-06-23-agent-status-integration-install-design.md` (only if implementation reveals a real spec mismatch)

- [ ] **Step 1: Add a small settings hint that setup lives in the Agent Lights panel**

```swift
Text("Use the Agent Lights menu bar panel to install or remove the OpenCode plugin and Codex hook.")
    .font(.system(size: 12))
    .foregroundColor(.appSecondaryText)
    .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Run the Debug build**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manually verify the Agent Lights panel behavior**

Run:

```bash
open /Users/zyao/Library/Developer/Xcode/DerivedData/pulse-*/Build/Products/Debug/Pulse.app
```

Expected:

- left-click on the Agent Lights menu item opens the standalone panel
- each enabled agent shows an integration card above its slots
- OpenCode shows plugin install controls
- Codex shows hook install controls and inline `/hooks` activation guidance
- existing slot delete and clear actions still work

- [ ] **Step 5: Commit the final integration-install polish**

```bash
git add pulse/Views/SettingsView.swift
git commit -m "feat: finish agent integration install flow"
```

## Self-Review

Spec coverage check:

- Integration card UI: covered by Task 4
- Machine-wide install model: covered by Tasks 2 and 3
- Shared sender: covered by Task 2
- Thin OpenCode plugin and Codex hook adapters: covered by Task 2
- Codex inline activation guidance: covered by Task 4
- Uninstall and ownership safety: covered by Task 3
- Verification and no regression to existing behavior: covered by Task 5

Placeholder scan:

- No `TODO`, `TBD`, or “implement later” placeholders remain.
- Each code-changing step contains example code or exact interfaces to add.

Type consistency check:

- `AgentIntegrationManager`, `AgentIntegrationStatus`, and `AgentIntegrationState` are defined in Task 1 and reused consistently later.
- `install`, `reinstall`, `uninstall`, and `status(for:)` are named consistently across Tasks 2 to 4.
