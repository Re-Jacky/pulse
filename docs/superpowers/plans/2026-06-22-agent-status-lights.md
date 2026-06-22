# Agent Status Lights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live, plugin-driven agent status lights directly to the macOS menu bar, with a dedicated `Agent Lights` feature flag in Settings, per-agent visibility controls for OpenCode and Codex, and persistent per-session slots plus a management surface for inspection and cleanup.

**Architecture:** `AppDelegate` owns a new runtime-status subsystem that is fully separate from the existing Agent Usage analytics path. A dedicated `AgentLightsSettings` model controls whether the feature is enabled and which agents are visible. A local status server receives normalized lifecycle events from agent integrations, an `AgentSessionSlotStore` persists and reconciles per-agent slots, and the `NSStatusItem` renders a compact custom view showing only enabled agent groups with colored session lights. The existing Pulse panel remains the management surface for mapping lights back to projects and deleting stale slots.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Combine, Network, UserDefaults or lightweight JSON persistence, XCTest, Xcode project `pulse.xcodeproj`, macOS 14+.

---

## File Map

- Create: `pulse/Managers/AgentStatusModels.swift`
  Defines runtime agent identifiers, event kinds, slot states, agent groups, and persistence payloads for the new live-status subsystem.
- Create: `pulse/Managers/AgentStatusStore.swift`
  Owns slot assignment, placeholder creation, persistence, deletion, overflow calculation, and event-to-state reconciliation.
- Create: `pulse/Managers/AgentLightsSettings.swift`
  Stores the `Enable Agent Lights` feature flag and the set of enabled live-status agents, independent from `AgentUsageSettings`.
- Create: `pulse/Managers/PulseAgentStatusServer.swift`
  Hosts the local event endpoint, decodes normalized status payloads, and forwards valid events to the store on the main actor.
- Create: `pulse/Views/MenuBarStatusItemView.swift`
  Implements a compact AppKit-backed status button subview that renders the Pulse base icon, agent icons, and light slots directly in the menu bar.
- Create: `pulse/Views/AgentStatusManagementView.swift`
  Adds a SwiftUI management surface listing slots by agent with delete and clear actions.
- Create: `pulseTests/AgentStatusStoreTests.swift`
  Covers placeholder creation, slot reuse, stable ordering, deletion behavior, and overflow handling.
- Create: `pulseTests/PulseAgentStatusServerTests.swift`
  Covers malformed event rejection and normalized event forwarding without using a real socket.
- Modify: `pulse/App/AppDelegate.swift`
  Owns the new settings model, store, and server, swaps the status button image for the custom menu bar view, reacts to `Agent Lights` settings changes, and injects the management surface dependencies.
- Modify: `pulse/Views/PopoverView.swift`
  Adds a lightweight `Status` tab or section host for slot inspection and cleanup without making the panel the primary live surface.
- Modify: `pulse/Views/SettingsView.swift`
  Adds a new `Agent Lights` tab with feature enable toggle, per-agent toggles, integration guidance, and cleanup controls.
- Modify: `pulse/Managers/AgentUsageModels.swift`
  Reuse or align agent identifiers where helpful, without merging the historical usage path into the live runtime path.
- Modify: `pulse.xcodeproj/project.pbxproj`
  Add all new Swift source and test files to the app and test targets.

No changes should remove `LSUIElement = true`, and no live-status logic should read agent SQLite databases.

---

### Task 1: Add The Agent Lights Settings Model

**Files:**
- Create: `pulse/Managers/AgentLightsSettings.swift`
- Create: `pulseTests/AgentLightsSettingsTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing settings tests**

Create `pulseTests/AgentLightsSettingsTests.swift`:

```swift
import XCTest
@testable import Pulse

final class AgentLightsSettingsTests: XCTestCase {
    func testDefaultsToDisabledWithAllSupportedAgentsSelected() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let settings = AgentLightsSettings(userDefaults: defaults)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.selectedAgents, Set(AgentStatusAgent.allCases))
    }
}
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentLightsSettingsTests/testDefaultsToDisabledWithAllSupportedAgentsSelected
```

Expected: FAIL because `AgentLightsSettings` does not exist.

- [ ] **Step 3: Implement the settings model**

Create `pulse/Managers/AgentLightsSettings.swift`:

```swift
import Combine
import Foundation

final class AgentLightsSettings: ObservableObject {
    private enum Keys {
        static let isEnabled = "agentLights.isEnabled"
        static let selectedAgents = "agentLights.selectedAgents"
    }

    @Published var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var selectedAgents: Set<AgentStatusAgent> {
        didSet {
            let rawValues = selectedAgents.map(\.rawValue).sorted()
            userDefaults.set(rawValues, forKey: Keys.selectedAgents)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        let savedRawValues = userDefaults.stringArray(forKey: Keys.selectedAgents) ?? AgentStatusAgent.allCases.map(\.rawValue)
        let restored = Set(savedRawValues.compactMap(AgentStatusAgent.init(rawValue:)))
        self.selectedAgents = restored.isEmpty ? Set(AgentStatusAgent.allCases) : restored
    }

    var enabledAgents: [AgentStatusAgent] {
        AgentStatusAgent.allCases.filter { selectedAgents.contains($0) }
    }
}
```

- [ ] **Step 4: Register the settings model and test files in Xcode**

Run:

```bash
ruby add_files.rb pulse/Managers/AgentLightsSettings.swift pulseTests/AgentLightsSettingsTests.swift
```

Expected: both files are added to the app and test targets in `pulse.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run the targeted settings tests**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentLightsSettingsTests
```

Expected: PASS for the default feature-flag behavior.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentLightsSettings.swift pulseTests/AgentLightsSettingsTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent lights settings model"
```

---

### Task 2: Add The Runtime Status Models

**Files:**
- Create: `pulse/Managers/AgentStatusModels.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing model test**

Create `pulseTests/AgentStatusStoreTests.swift` with the first test:

```swift
import XCTest
@testable import Pulse

final class AgentStatusStoreTests: XCTestCase {
    func testInitialStateCreatesOnePlaceholderPerEnabledAgent() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode, .codex]
        )

        XCTAssertEqual(store.groups.count, 2)
        XCTAssertEqual(store.groups.first(where: { $0.agent == .openCode })?.slots.map(\.state), [.empty])
        XCTAssertEqual(store.groups.first(where: { $0.agent == .codex })?.slots.map(\.state), [.empty])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests/testInitialStateCreatesOnePlaceholderPerEnabledAgent
```

Expected: FAIL because `AgentStatusStore`, `AgentStatusAgent`, `AgentStatusGroup`, and `InMemoryAgentStatusPersistence` do not exist yet.

- [ ] **Step 3: Write the shared runtime model types**

Create `pulse/Managers/AgentStatusModels.swift`:

```swift
import Foundation

enum AgentStatusAgent: String, CaseIterable, Codable, Hashable, Identifiable {
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .codex: return "Codex"
        }
    }
}

enum AgentSessionLightState: String, Codable, Hashable {
    case empty
    case working
    case idle
    case error
}

enum PulseAgentStatusEventKind: String, Codable {
    case sessionStarted = "session.started"
    case sessionWorking = "session.working"
    case sessionIdle = "session.idle"
    case sessionError = "session.error"
    case sessionClosed = "session.closed"
}

struct PulseAgentStatusEvent: Codable, Equatable {
    let agent: AgentStatusAgent
    let sessionID: String
    let projectPath: String
    let title: String
    let timestamp: Date
    let kind: PulseAgentStatusEventKind
    let message: String?
}

struct AgentSessionSlot: Identifiable, Codable, Equatable {
    let id: UUID
    let agent: AgentStatusAgent
    var sessionID: String?
    var projectPath: String?
    var projectName: String?
    var title: String?
    var state: AgentSessionLightState
    var lastTransitionAt: Date?
    var lastSeenAt: Date?

    var isPlaceholder: Bool { state == .empty && sessionID == nil }
}

struct AgentStatusGroup: Identifiable, Equatable {
    let agent: AgentStatusAgent
    var slots: [AgentSessionSlot]
    var overflowCount: Int

    var id: String { agent.rawValue }
}

struct PersistedAgentStatusStore: Codable, Equatable {
    var groups: [PersistedAgentStatusGroup]
}

struct PersistedAgentStatusGroup: Codable, Equatable {
    let agent: AgentStatusAgent
    var slots: [AgentSessionSlot]
}
```

- [ ] **Step 4: Register the new source file in Xcode**

Use the repo helper so the file is added to the `pulse` target:

```bash
ruby add_files.rb pulse/Managers/AgentStatusModels.swift
```

Expected: `pulse.xcodeproj/project.pbxproj` gains a file reference and a `Sources` build entry for `AgentStatusModels.swift`.

- [ ] **Step 5: Run the targeted test again**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests/testInitialStateCreatesOnePlaceholderPerEnabledAgent
```

Expected: FAIL, now limited to missing store and persistence implementations.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentStatusModels.swift pulseTests/AgentStatusStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent status runtime models"
```

---

### Task 3: Build The Slot Store With Placeholder, Reuse, And Delete Rules

**Files:**
- Create: `pulse/Managers/AgentStatusStore.swift`
- Modify: `pulseTests/AgentStatusStoreTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the next failing reconciliation tests**

Extend `pulseTests/AgentStatusStoreTests.swift`:

```swift
func testNewSessionReusesFirstPlaceholderSlot() {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.openCode]
    )

    store.apply(
        PulseAgentStatusEvent(
            agent: .openCode,
            sessionID: "session-1",
            projectPath: "/tmp/pulse",
            title: "Fix menu bar",
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .sessionWorking,
            message: nil
        )
    )

    let slots = store.groups[0].slots
    XCTAssertEqual(slots.count, 1)
    XCTAssertEqual(slots[0].state, .working)
    XCTAssertEqual(slots[0].sessionID, "session-1")
    XCTAssertEqual(slots[0].projectName, "pulse")
}

func testIdleAndErrorSessionsStayVisibleUntilDeleted() {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.codex]
    )

    store.apply(PulseAgentStatusEvent(agent: .codex, sessionID: "a", projectPath: "/tmp/a", title: "A", timestamp: Date(timeIntervalSince1970: 10), kind: .sessionIdle, message: nil))
    store.apply(PulseAgentStatusEvent(agent: .codex, sessionID: "b", projectPath: "/tmp/b", title: "B", timestamp: Date(timeIntervalSince1970: 11), kind: .sessionError, message: "failed"))

    XCTAssertEqual(store.groups[0].slots.map(\.state), [.idle, .error])

    store.deleteSlot(agent: .codex, slotID: store.groups[0].slots[0].id)

    XCTAssertEqual(store.groups[0].slots.map(\.state), [.error])
}
```

- [ ] **Step 2: Run the targeted store tests**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests
```

Expected: FAIL because the store implementation and delete APIs do not exist.

- [ ] **Step 3: Implement the store and in-memory persistence**

Create `pulse/Managers/AgentStatusStore.swift`:

```swift
import Combine
import Foundation

protocol AgentStatusPersistence {
    func load() -> PersistedAgentStatusStore?
    func save(_ store: PersistedAgentStatusStore)
}

final class InMemoryAgentStatusPersistence: AgentStatusPersistence {
    private var stored: PersistedAgentStatusStore?

    func load() -> PersistedAgentStatusStore? { stored }
    func save(_ store: PersistedAgentStatusStore) { stored = store }
}

@MainActor
final class AgentStatusStore: ObservableObject {
    @Published private(set) var groups: [AgentStatusGroup] = []
    private let persistence: AgentStatusPersistence
    private let enabledAgents: [AgentStatusAgent]
    private let visibleSlotCap = 4

    init(persistence: AgentStatusPersistence, enabledAgents: [AgentStatusAgent]) {
        self.persistence = persistence
        self.enabledAgents = enabledAgents
        self.groups = Self.bootstrapGroups(from: persistence.load(), enabledAgents: enabledAgents)
        persist()
    }

    func apply(_ event: PulseAgentStatusEvent) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == event.agent }) else { return }
        if let slotIndex = groups[groupIndex].slots.firstIndex(where: { $0.sessionID == event.sessionID }) {
            updateSlot(at: slotIndex, in: groupIndex, with: event)
        } else if let placeholderIndex = groups[groupIndex].slots.firstIndex(where: \.isPlaceholder) {
            updateSlot(at: placeholderIndex, in: groupIndex, with: event)
        } else {
            groups[groupIndex].slots.append(makeSlot(from: event))
        }
        groups[groupIndex].overflowCount = max(0, groups[groupIndex].slots.count - visibleSlotCap)
        persist()
    }

    func deleteSlot(agent: AgentStatusAgent, slotID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else { return }
        groups[groupIndex].slots.removeAll { $0.id == slotID }
        if groups[groupIndex].slots.isEmpty {
            groups[groupIndex].slots = [Self.placeholder(for: agent)]
        }
        groups[groupIndex].overflowCount = max(0, groups[groupIndex].slots.count - visibleSlotCap)
        persist()
    }

    private func updateSlot(at slotIndex: Int, in groupIndex: Int, with event: PulseAgentStatusEvent) {
        groups[groupIndex].slots[slotIndex] = makeSlot(from: event, existingID: groups[groupIndex].slots[slotIndex].id)
    }

    private func makeSlot(from event: PulseAgentStatusEvent, existingID: UUID = UUID()) -> AgentSessionSlot {
        AgentSessionSlot(
            id: existingID,
            agent: event.agent,
            sessionID: event.sessionID,
            projectPath: event.projectPath,
            projectName: URL(fileURLWithPath: event.projectPath).lastPathComponent,
            title: event.title,
            state: Self.map(event.kind),
            lastTransitionAt: event.timestamp,
            lastSeenAt: event.timestamp
        )
    }

    private func persist() {
        persistence.save(
            PersistedAgentStatusStore(
                groups: groups.map { PersistedAgentStatusGroup(agent: $0.agent, slots: $0.slots) }
            )
        )
    }

    private static func bootstrapGroups(from persisted: PersistedAgentStatusStore?, enabledAgents: [AgentStatusAgent]) -> [AgentStatusGroup] {
        enabledAgents.map { agent in
            let restored = persisted?.groups.first(where: { $0.agent == agent })?.slots ?? []
            let slots = restored.isEmpty ? [placeholder(for: agent)] : restored
            return AgentStatusGroup(agent: agent, slots: slots, overflowCount: 0)
        }
    }

    private static func placeholder(for agent: AgentStatusAgent) -> AgentSessionSlot {
        AgentSessionSlot(id: UUID(), agent: agent, sessionID: nil, projectPath: nil, projectName: nil, title: nil, state: .empty, lastTransitionAt: nil, lastSeenAt: nil)
    }

    private static func map(_ kind: PulseAgentStatusEventKind) -> AgentSessionLightState {
        switch kind {
        case .sessionStarted, .sessionWorking: return .working
        case .sessionIdle, .sessionClosed: return .idle
        case .sessionError: return .error
        }
    }
}
```

- [ ] **Step 4: Add the new store file to the Xcode project**

```bash
ruby add_files.rb pulse/Managers/AgentStatusStore.swift pulseTests/AgentStatusStoreTests.swift
```

Expected: both app and test target entries appear in `pulse.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run the store tests to make sure they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests
```

Expected: PASS for the placeholder, reuse, and delete tests.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/AgentStatusStore.swift pulseTests/AgentStatusStoreTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent session slot store"
```

---

### Task 4: Add Persistence, Clear Actions, And Overflow Coverage

**Files:**
- Modify: `pulse/Managers/AgentStatusStore.swift`
- Modify: `pulseTests/AgentStatusStoreTests.swift`

- [ ] **Step 1: Add failing tests for clear actions and overflow**

Append to `pulseTests/AgentStatusStoreTests.swift`:

```swift
func testClearIdleSlotsLeavesOnePlaceholder() {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.openCode]
    )

    store.apply(PulseAgentStatusEvent(agent: .openCode, sessionID: "idle-1", projectPath: "/tmp/p1", title: "P1", timestamp: Date(), kind: .sessionIdle, message: nil))
    store.apply(PulseAgentStatusEvent(agent: .openCode, sessionID: "idle-2", projectPath: "/tmp/p2", title: "P2", timestamp: Date(), kind: .sessionIdle, message: nil))

    store.clearIdleSlots(for: .openCode)

    XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])
}

func testOverflowCountTracksSlotsBeyondVisibleCap() {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.codex]
    )

    for index in 0..<5 {
        store.apply(PulseAgentStatusEvent(agent: .codex, sessionID: "session-\(index)", projectPath: "/tmp/\(index)", title: "T\(index)", timestamp: Date(), kind: .sessionWorking, message: nil))
    }

    XCTAssertEqual(store.groups[0].slots.count, 5)
    XCTAssertEqual(store.groups[0].overflowCount, 1)
}
```

- [ ] **Step 2: Run the targeted tests**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests
```

Expected: FAIL because `clearIdleSlots(for:)` does not exist yet.

- [ ] **Step 3: Implement JSON-backed persistence and clear helpers**

Replace the persistence portion of `pulse/Managers/AgentStatusStore.swift` with:

```swift
protocol AgentStatusPersistence {
    func load() -> PersistedAgentStatusStore?
    func save(_ store: PersistedAgentStatusStore)
}

final class UserDefaultsAgentStatusPersistence: AgentStatusPersistence {
    private let defaults: UserDefaults
    private let key = "agentStatusStore"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedAgentStatusStore? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedAgentStatusStore.self, from: data)
    }

    func save(_ store: PersistedAgentStatusStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: key)
    }
}
```

And add these store methods:

```swift
func clearIdleSlots(for agent: AgentStatusAgent) {
    guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else { return }
    groups[groupIndex].slots.removeAll { $0.state == .idle }
    if groups[groupIndex].slots.isEmpty {
        groups[groupIndex].slots = [Self.placeholder(for: agent)]
    }
    groups[groupIndex].overflowCount = max(0, groups[groupIndex].slots.count - visibleSlotCap)
    persist()
}

func clearAllSlots(for agent: AgentStatusAgent) {
    guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else { return }
    groups[groupIndex].slots = [Self.placeholder(for: agent)]
    groups[groupIndex].overflowCount = 0
    persist()
}
```

- [ ] **Step 4: Re-run the full store test file**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests
```

Expected: PASS for placeholder, reuse, delete, clear, and overflow coverage.

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentStatusStore.swift pulseTests/AgentStatusStoreTests.swift
git commit -m "feat: persist and manage agent status slots"
```

---

### Task 5: Add The Local Status Server And Event Validation

**Files:**
- Create: `pulse/Managers/PulseAgentStatusServer.swift`
- Create: `pulseTests/PulseAgentStatusServerTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing server tests around decoding and forwarding**

Create `pulseTests/PulseAgentStatusServerTests.swift`:

```swift
import XCTest
@testable import Pulse

final class PulseAgentStatusServerTests: XCTestCase {
    @MainActor
    func testHandlePayloadForwardsValidEventToStore() throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let server = PulseAgentStatusServer(store: store)
        let payload = """
        {"agent":"opencode","sessionID":"s1","projectPath":"/tmp/pulse","title":"Task","timestamp":"1970-01-01T00:01:40Z","kind":"session.working"}
        """.data(using: .utf8)!

        try server.handlePayload(payload)

        XCTAssertEqual(store.groups[0].slots.first?.sessionID, "s1")
        XCTAssertEqual(store.groups[0].slots.first?.state, .working)
    }

    @MainActor
    func testHandlePayloadRejectsMalformedEvent() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )
        let server = PulseAgentStatusServer(store: store)

        XCTAssertThrowsError(try server.handlePayload(Data("{}".utf8)))
        XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])
    }
}
```

- [ ] **Step 2: Run the targeted server tests**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/PulseAgentStatusServerTests
```

Expected: FAIL because `PulseAgentStatusServer` does not exist.

- [ ] **Step 3: Implement the server with a testable payload entry point**

Create `pulse/Managers/PulseAgentStatusServer.swift`:

```swift
import Foundation

enum PulseAgentStatusServerError: Error {
    case invalidPayload
}

@MainActor
final class PulseAgentStatusServer {
    private let store: AgentStatusStore
    private let decoder: JSONDecoder

    init(store: AgentStatusStore) {
        self.store = store
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func start() {
    }

    func handlePayload(_ payload: Data) throws {
        let event = try decoder.decode(PulseAgentStatusEvent.self, from: payload)
        guard event.sessionID.isEmpty == false, event.projectPath.isEmpty == false else {
            throw PulseAgentStatusServerError.invalidPayload
        }
        store.apply(event)
    }
}
```

- [ ] **Step 4: Add the server source and test file to Xcode**

```bash
ruby add_files.rb pulse/Managers/PulseAgentStatusServer.swift pulseTests/PulseAgentStatusServerTests.swift
```

Expected: both files appear in the app and test target source phases.

- [ ] **Step 5: Run the targeted server tests**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/PulseAgentStatusServerTests
```

Expected: PASS for valid forwarding and malformed payload rejection.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/PulseAgentStatusServer.swift pulseTests/PulseAgentStatusServerTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add pulse agent status server"
```

---

### Task 6: Render Agent Groups And Lights In The Menu Bar

**Files:**
- Create: `pulse/Views/MenuBarStatusItemView.swift`
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the failing build-time integration point**

In `pulse/App/AppDelegate.swift`, replace the `statusItem.button?.image` setup in `applicationDidFinishLaunching` with:

```swift
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = nil
let statusView = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
statusItem.button?.addSubview(statusView)
```

Expected: this will not compile yet because `MenuBarStatusItemView` does not exist and the status store is not injected.

- [ ] **Step 2: Run a build to surface the missing renderer**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: FAIL with missing `MenuBarStatusItemView` and missing runtime-status dependencies in `AppDelegate`.

- [ ] **Step 3: Implement the menu bar view**

Create `pulse/Views/MenuBarStatusItemView.swift`:

```swift
import AppKit
import Combine

final class MenuBarStatusItemView: NSControl {
    private var cancellable: AnyCancellable?
    private let stackView = NSStackView()
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func bind(to store: AgentStatusStore) {
        cancellable = store.$groups.receive(on: RunLoop.main).sink { [weak self] groups in
            self?.render(groups: groups)
        }
        render(groups: store.groups)
    }

    private func setupView() {
        wantsLayer = true
        stackView.orientation = .horizontal
        stackView.spacing = 6
        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    override func mouseUp(with event: NSEvent) {
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    private func render(groups: [AgentStatusGroup]) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stackView.addArrangedSubview(makePulseBadge())
        groups.forEach { stackView.addArrangedSubview(makeGroupView(for: $0)) }
    }
}
```

- [ ] **Step 4: Wire the store and renderer in `AppDelegate`**

In `pulse/App/AppDelegate.swift`, add these properties:

```swift
private let agentLightsSettings = AgentLightsSettings()
private let agentStatusStore = AgentStatusStore(
    persistence: UserDefaultsAgentStatusPersistence(),
    enabledAgents: AgentStatusAgent.allCases
)
private lazy var agentStatusServer = PulseAgentStatusServer(store: agentStatusStore)
```

Then replace the status item setup in `applicationDidFinishLaunching` with:

```swift
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
if let button = statusItem.button {
    button.image = nil
    button.removeAllSubviews()
    let statusView = MenuBarStatusItemView(frame: button.bounds)
    statusView.autoresizingMask = [.width, .height]
    statusView.bind(to: agentStatusStore, settings: agentLightsSettings)
    statusView.onLeftClick = { [weak self] in self?.togglePanel() }
    statusView.onRightClick = { [weak self] in self?.showContextMenu() }
    button.addSubview(statusView)
}
agentStatusServer.start()
```

Add this helper in `pulse/App/AppDelegate.swift` so the status button can be cleared before the custom subview is attached:

```swift
private extension NSView {
    func removeAllSubviews() {
        subviews.forEach { $0.removeFromSuperview() }
    }
}
```

- [ ] **Step 5: Register the new menu bar renderer file**

```bash
ruby add_files.rb pulse/Views/MenuBarStatusItemView.swift
```

Expected: the renderer is compiled into the `pulse` target.

- [ ] **Step 6: Build to verify the custom status item compiles**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: PASS, or remaining failures limited to concrete rendering helpers such as `makePulseBadge()` and `makeGroupView(for:)`.

- [ ] **Step 7: Commit**

```bash
git add pulse/App/AppDelegate.swift pulse/Views/MenuBarStatusItemView.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: render agent status lights in menu bar"
```

---

### Task 7: Add The Management Surface To The Pulse UI

**Files:**
- Create: `pulse/Views/AgentStatusManagementView.swift`
- Modify: `pulse/Views/PopoverView.swift`
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write a failing build integration for the management view**

In `pulse/Views/PopoverView.swift`, add a `Status` tab to `availableTabs` and a placeholder view reference:

```swift
var tabs: [(String, Int)] = [("Stats", 0), ("Processes", 1), ("Status", 2)]
if agentUsageSettings.effectiveEnabled {
    tabs.append(("Agent", 3))
}
```

And inside the `ZStack`:

```swift
AgentStatusManagementView()
    .opacity(selectedTab == 2 ? 1 : 0)
    .allowsHitTesting(selectedTab == 2)
```

Expected: compile failure because `AgentStatusManagementView` does not exist and selected-tab numbering is now outdated.

- [ ] **Step 2: Run a build to confirm the management view is the remaining gap**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: FAIL with missing `AgentStatusManagementView` and any tab-index references that still assume `Agent` is tag `2`.

- [ ] **Step 3: Implement the management view**

Create `pulse/Views/AgentStatusManagementView.swift`:

```swift
import SwiftUI

struct AgentStatusManagementView: View {
    @EnvironmentObject var agentStatusStore: AgentStatusStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(agentStatusStore.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.agent.displayName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.appPrimaryText)

                        ForEach(group.slots) { slot in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(color(for: slot.state))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slot.projectName ?? "Empty Slot")
                                        .foregroundColor(.appPrimaryText)
                                    Text(slot.title ?? slot.state.rawValue.capitalized)
                                        .font(.system(size: 12))
                                        .foregroundColor(.appSecondaryText)
                                }
                                Spacer()
                                Button("Delete") {
                                    agentStatusStore.deleteSlot(agent: group.agent, slotID: slot.id)
                                }
                                .disabled(slot.isPlaceholder)
                            }
                        }

                        HStack {
                            Button("Clear Idle") { agentStatusStore.clearIdleSlots(for: group.agent) }
                            Button("Clear All") { agentStatusStore.clearAllSlots(for: group.agent) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func color(for state: AgentSessionLightState) -> Color {
        switch state {
        case .empty: return .appDivider
        case .working: return .orange
        case .idle: return .green
        case .error: return .red
        }
    }
}
```

- [ ] **Step 4: Inject the store and fix the tab numbering**

In `pulse/App/AppDelegate.swift`, inject the new environment object when building `PopoverView`:

```swift
rootView: PopoverView()
    .environmentObject(monitor)
    .environmentObject(themeManager)
    .environmentObject(agentUsageSettings)
    .environmentObject(agentUsageStore)
    .environmentObject(agentStatusStore)
    .environmentObject(updateManager)
```

And in `pulse/Views/PopoverView.swift`, update the agent-tab references from `2` to `3`:

```swift
if agentUsageSettings.effectiveEnabled {
    tabs.append(("Agent", 3))
}
```

```swift
if agentUsageSettings.effectiveEnabled {
    AgentUsageView()
        .opacity(selectedTab == 3 ? 1 : 0)
        .allowsHitTesting(selectedTab == 3)
}
```

```swift
guard agentUsageSettings.effectiveEnabled, selectedTab == 3 else { return }
```

- [ ] **Step 5: Register the new view file and build**

Run:

```bash
ruby add_files.rb pulse/Views/AgentStatusManagementView.swift
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: PASS, with the panel now compiling against the new management surface.

- [ ] **Step 6: Commit**

```bash
git add pulse/Views/AgentStatusManagementView.swift pulse/Views/PopoverView.swift pulse/App/AppDelegate.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add agent status management view"
```

---

### Task 8: Add The `Agent Lights` Settings Tab And Visibility Rules

**Files:**
- Modify: `pulse/Managers/AgentStatusStore.swift`
- Modify: `pulse/Views/SettingsView.swift`
- Modify: `pulse/App/AppDelegate.swift`

- [ ] **Step 1: Add the failing settings tab references**

In `pulse/Views/SettingsView.swift`, extend `Section`:

```swift
private enum Section: Hashable {
    case theme
    case agentUsage
    case agentLights
    case updates
}
```

And add a sidebar button:

```swift
sidebarButton(title: "Agent Lights", systemImage: "dot.radiowaves.left.and.right", section: .agentLights)
```

Expected: compile failure because `agentLightsContent` does not exist.

- [ ] **Step 2: Run a build to confirm the missing content**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: FAIL with missing `agentLightsContent`.

- [ ] **Step 3: Add store filtering support for enabled agents**

In `pulse/Managers/AgentStatusStore.swift`, add:

```swift
func visibleGroups(enabledAgents: Set<AgentStatusAgent>, featureEnabled: Bool) -> [AgentStatusGroup] {
    guard featureEnabled else { return [] }
    return groups.filter { enabledAgents.contains($0.agent) }
}
```

- [ ] **Step 4: Implement the `Agent Lights` settings content**

In `pulse/Views/SettingsView.swift`, add:

```swift
case .agentLights:
    agentLightsContent
```

And define:

```swift
@EnvironmentObject var agentLightsSettings: AgentLightsSettings
@EnvironmentObject var agentStatusStore: AgentStatusStore

private var agentLightsContent: some View {
    VStack(alignment: .leading, spacing: 14) {
        Text("Agent Lights")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text("Show live agent session lights directly in the menu bar when Pulse-compatible plugin or hook integrations are installed.")
            .font(.system(size: 13))
            .foregroundColor(.appSecondaryText)
            .fixedSize(horizontal: false, vertical: true)

        Toggle("Enable Agent Lights", isOn: $agentLightsSettings.isEnabled)
            .toggleStyle(.switch)

        VStack(alignment: .leading, spacing: 10) {
            Text("Agents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            ForEach(AgentStatusAgent.allCases) { agent in
                Toggle(agent.displayName, isOn: Binding(
                    get: { agentLightsSettings.selectedAgents.contains(agent) },
                    set: { isSelected in
                        var next = agentLightsSettings.selectedAgents
                        if isSelected {
                            next.insert(agent)
                        } else {
                            next.remove(agent)
                        }
                        agentLightsSettings.selectedAgents = next
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .disabled(agentLightsSettings.isEnabled == false)

        Text("Setup")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text("OpenCode: install the Pulse plugin. Codex: install the Pulse hook configuration. Pulse does not fall back to database or transcript polling for this feature.")
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)
            .fixedSize(horizontal: false, vertical: true)

        Button("Clear All OpenCode Slots") {
            agentStatusStore.clearAllSlots(for: .openCode)
        }

        Button("Clear All Codex Slots") {
            agentStatusStore.clearAllSlots(for: .codex)
        }
    }
}
```

- [ ] **Step 5: Inject the settings model into the app and settings window**

In `pulse/App/AppDelegate.swift`, add:

```swift
private func setupAgentLightsObservation() {
    agentLightsSettings.$isEnabled
        .combineLatest(agentLightsSettings.$selectedAgents)
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
            self?.refreshStatusItemLayout()
        }
        .store(in: &cancellables)
}
```

Call it from `applicationDidFinishLaunching()` after `setupFeatureObservation()`.

In `pulse/App/AppDelegate.swift`, update the settings window hosting controller:

```swift
rootView: SettingsView()
    .environmentObject(themeManager)
    .environmentObject(agentUsageSettings)
    .environmentObject(agentLightsSettings)
    .environmentObject(agentStatusStore)
    .environmentObject(updateManager)
```

- [ ] **Step 6: Filter the menu bar rendering to enabled agents only**

In `pulse/Views/MenuBarStatusItemView.swift`, change the binding signature:

```swift
func bind(to store: AgentStatusStore, settings: AgentLightsSettings) {
    cancellable = Publishers.CombineLatest(store.$groups, settings.$selectedAgents.combineLatest(settings.$isEnabled))
        .receive(on: RunLoop.main)
        .sink { [weak self] groups, selection in
            let visibleGroups = selection.1 ? groups.filter { selection.0.contains($0.agent) } : []
            self?.render(groups: visibleGroups)
        }
    let visibleGroups = settings.isEnabled ? store.groups.filter { settings.selectedAgents.contains($0.agent) } : []
    render(groups: visibleGroups)
}
```

- [ ] **Step 7: Build to verify the settings wiring**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: PASS with the new `Agent Lights` tab available and only enabled agents eligible for menu bar display.

- [ ] **Step 8: Commit**

```bash
git add pulse/Managers/AgentStatusStore.swift pulse/Views/SettingsView.swift pulse/Views/MenuBarStatusItemView.swift pulse/App/AppDelegate.swift
git commit -m "feat: add agent lights settings tab"
```

---

### Task 9: Finish Transport Wiring And Run Full Verification

**Files:**
- Modify: `pulse/Managers/PulseAgentStatusServer.swift`
- Modify: `pulse/App/AppDelegate.swift`
- Modify: `pulseTests/PulseAgentStatusServerTests.swift`

- [ ] **Step 1: Add a transport-oriented failing test seam**

Extend `pulseTests/PulseAgentStatusServerTests.swift`:

```swift
@MainActor
func testStartIsSafeToCallMoreThanOnce() {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.openCode]
    )
    let server = PulseAgentStatusServer(store: store)

    XCTAssertNoThrow(server.start())
    XCTAssertNoThrow(server.start())
}
```

- [ ] **Step 2: Run the server tests**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/PulseAgentStatusServerTests
```

Expected: FAIL if `start()` is still a placeholder or not idempotent.

- [ ] **Step 3: Implement the V1 loopback socket start path and idempotency**

Update `pulse/Managers/PulseAgentStatusServer.swift`:

```swift
import Foundation
import Network

@MainActor
final class PulseAgentStatusServer {
    private let store: AgentStatusStore
    private let decoder: JSONDecoder
    private var isRunning = false
    private var listener: NWListener?

    init(store: AgentStatusStore) {
        self.store = store
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func start() {
        guard isRunning == false else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 45821)!)
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            self?.receiveNextMessage(on: connection)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        isRunning = true
    }

    nonisolated private func receiveNextMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, data.isEmpty == false {
                Task { @MainActor in
                    try? self?.handlePayload(data)
                }
            }
            if error == nil, isComplete == false {
                self?.receiveNextMessage(on: connection)
            } else {
                connection.cancel()
            }
        }
    }
}
```

The implementation is complete when:

- repeated `start()` calls are harmless
- the transport setup path is isolated from payload decoding
- received data still funnels through `handlePayload(_:)`

- [ ] **Step 4: Run all targeted tests and the full suite**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/AgentStatusStoreTests
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:PulseTests/PulseAgentStatusServerTests
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
```

Expected: PASS for the new test files and PASS for the full `pulseTests` suite.

- [ ] **Step 5: Run the app build**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: PASS with the app target building cleanly after all runtime-status changes.

- [ ] **Step 6: Manual verification**

Launch the app and verify:

```text
1. When `Enable Agent Lights` is off, no extra agent lights are shown in the menu bar.
2. When `Enable Agent Lights` is on, only checked agents show groups in the menu bar, each starting with one empty placeholder light.
3. Simulated or test-fed status events replace placeholders with orange, green, and red lights without reordering other slots.
4. Multiple sessions for one agent append new lights and keep stable positions.
5. Deleting a slot removes only that slot and keeps at least one empty placeholder when a visible group becomes empty.
6. The Status management view shows slot-to-project mapping and the clear actions work.
7. The Settings > Agent Lights tab explains the integration requirement and the enable/selection controls work independently from Agent Usage.
```

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/PulseAgentStatusServer.swift pulse/App/AppDelegate.swift pulseTests/PulseAgentStatusServerTests.swift
git commit -m "feat: finish live agent status lights"
```
