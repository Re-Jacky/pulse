# Agent Status Per-Agent Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Agent Lights popup show only the clicked agent's details, with each menu bar agent icon-plus-lights area acting as that agent's click target.

**Architecture:** Keep the existing single floating `agentStatusPanel`, add selected-agent state in `AppDelegate`, and switch the panel content in place when a different agent group is clicked. Extend `MenuBarStatusItemView` to track rendered hit regions per visible agent group, then filter `AgentStatusManagementView` to the chosen group only.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Combine, XCTest.

---

## File Structure

- Modify: `pulse/Views/MenuBarStatusItemView.swift`
  Add per-agent hit zones, agent-specific click callbacks, and brighter overflow text styling.
- Modify: `pulse/App/AppDelegate.swift`
  Store the selected agent, open the existing panel for a specific agent, and swap content in place without creating another panel.
- Modify: `pulse/Views/AgentStatusManagementView.swift`
  Render one selected agent group instead of every group, keeping integration actions and session actions scoped to that agent.
- Modify: `pulse.xcodeproj/project.pbxproj`
  Only if test files or any new helper file references need project updates.
- Modify: `pulseTests/AgentStatusStoreTests.swift`
  Only if a small helper is useful to preserve current data assumptions while the UI changes.
- Create: `pulseTests/MenuBarStatusItemViewTests.swift`
  Cover click-zone resolution and overflow-region hit behavior.
- Create: `pulseTests/AgentStatusManagementViewTests.swift`
  Cover single-agent filtering behavior at the view-model/rendering boundary if practical in the current test setup.

### Task 1: Add failing click-zone tests for menu bar agent groups

**Files:**
- Create: `pulseTests/MenuBarStatusItemViewTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing tests for agent-group hit resolution**

```swift
import AppKit
import XCTest
@testable import Pulse

final class MenuBarStatusItemViewTests: XCTestCase {
    func testClickInOpenCodeGroupResolvesOpenCodeAgent() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        view.configureForTesting(
            groups: [
                AgentStatusGroup(
                    agent: .openCode,
                    slots: [makeSlot(agent: .openCode, state: .working)],
                    overflowCount: 0
                ),
                AgentStatusGroup(
                    agent: .codex,
                    slots: [makeSlot(agent: .codex, state: .idle)],
                    overflowCount: 0
                )
            ],
            isEnabled: true,
            selectedAgents: [.openCode, .codex]
        )

        XCTAssertEqual(view.agent(at: NSPoint(x: 8, y: 11)), .openCode)
    }

    func testOverflowMarkerBelongsToItsAgentGroup() {
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
        view.configureForTesting(
            groups: [
                AgentStatusGroup(
                    agent: .openCode,
                    slots: Array(repeating: makeSlot(agent: .openCode, state: .working), count: 4),
                    overflowCount: 1
                )
            ],
            isEnabled: true,
            selectedAgents: [.openCode]
        )

        XCTAssertEqual(view.agent(at: NSPoint(x: 62, y: 11)), .openCode)
    }
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/MenuBarStatusItemViewTests`

Expected: FAIL with missing `configureForTesting`, `agent(at:)`, and test helpers.

- [ ] **Step 3: Add minimal test helpers and hit-zone support hooks in `MenuBarStatusItemView`**

```swift
#if DEBUG
func configureForTesting(
    groups: [AgentStatusGroup],
    isEnabled: Bool,
    selectedAgents: Set<AgentStatusAgent>
) {
    render(groups: groups, isEnabled: isEnabled, selectedAgents: selectedAgents)
}

func agent(at point: NSPoint) -> AgentStatusAgent? {
    groupRegions.first(where: { $0.frame.contains(point) })?.agent
}
#endif
```

- [ ] **Step 4: Implement the actual region tracking in `MenuBarStatusItemView`**

```swift
private struct AgentGroupRegion {
    let agent: AgentStatusAgent
    let frame: NSRect
}

private var groupRegions: [AgentGroupRegion] = []

private func recalculateGroupRegions() {
    let groups = visibleGroups
    var cursorX = AgentStatusMenuBarMetrics.horizontalPadding
    var regions: [AgentGroupRegion] = []

    for (index, group) in groups.enumerated() {
        if index > 0 {
            cursorX += AgentStatusMenuBarMetrics.agentGroupGap
        }

        let startX = cursorX
        cursorX += AgentStatusMenuBarMetrics.agentIconAdvance
        cursorX += CGFloat(visibleSlots(for: group).count) * AgentStatusMenuBarMetrics.slotAdvance

        if group.overflowCount > 0 {
            cursorX += AgentStatusMenuBarMetrics.overflowAdvance
        }

        regions.append(
            AgentGroupRegion(
                agent: group.agent,
                frame: NSRect(x: startX, y: 0, width: cursorX - startX, height: bounds.height)
            )
        )
    }

    groupRegions = regions
}
```

- [ ] **Step 5: Re-run the targeted tests to verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/MenuBarStatusItemViewTests`

Expected: PASS for hit-resolution and overflow-region tests.

- [ ] **Step 6: Commit the menu bar hit-zone baseline**

```bash
git add pulse/Views/MenuBarStatusItemView.swift pulseTests/MenuBarStatusItemViewTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "test: add agent group hit zone coverage"
```

### Task 2: Route menu bar clicks to a specific selected agent

**Files:**
- Modify: `pulse/Views/MenuBarStatusItemView.swift`
- Modify: `pulse/App/AppDelegate.swift`

- [ ] **Step 1: Add a failing behavior test or lightweight assertion hook for selected-agent routing**

```swift
func testMouseDownUsesResolvedAgent() {
    let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
    view.configureForTesting(
        groups: [AgentStatusGroup(agent: .openCode, slots: [makeSlot(agent: .openCode, state: .working)], overflowCount: 0)],
        isEnabled: true,
        selectedAgents: [.openCode]
    )

    var selected: AgentStatusAgent?
    view.onLeftClickAgent = { selected = $0 }

    view.performLeftClickForTesting(at: NSPoint(x: 8, y: 11))

    XCTAssertEqual(selected, .openCode)
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/MenuBarStatusItemViewTests/testMouseDownUsesResolvedAgent`

Expected: FAIL with missing agent-specific click callback and testing hook.

- [ ] **Step 3: Replace generic panel callbacks with agent-specific callbacks in `MenuBarStatusItemView`**

```swift
var onLeftClickAgent: ((AgentStatusAgent) -> Void)?
var onRightClickAgent: ((AgentStatusAgent) -> Void)?

override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let agent = agent(at: point) else { return }

    if event.modifierFlags.contains(.control) {
        onRightClickAgent?(agent)
    } else {
        onLeftClickAgent?(agent)
    }
}

override func rightMouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let agent = agent(at: point) else { return }
    onRightClickAgent?(agent)
}
```

- [ ] **Step 4: Update `AppDelegate` to open the panel for the clicked agent**

```swift
private var selectedAgentStatusPanelAgent: AgentStatusAgent?

statusView.onLeftClickAgent = { [weak self] agent in
    self?.openAgentStatusPanel(for: agent)
}
statusView.onRightClickAgent = { [weak self] agent in
    self?.openAgentStatusPanel(for: agent)
}

private func openAgentStatusPanel(for agent: AgentStatusAgent) {
    selectedAgentStatusPanelAgent = agent
    if let panel = agentStatusPanel, panel.isVisible {
        refreshAgentStatusPanelContent()
        panel.makeKeyAndOrderFront(nil)
        return
    }

    openAgentStatusPanel()
}
```

- [ ] **Step 5: Re-run the menu bar tests and build the app**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/MenuBarStatusItemViewTests`

Expected: PASS

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit the click-routing behavior**

```bash
git add pulse/Views/MenuBarStatusItemView.swift pulse/App/AppDelegate.swift pulseTests/MenuBarStatusItemViewTests.swift
git commit -m "feat: route agent lights clicks by agent group"
```

### Task 3: Filter the agent status panel to the selected agent only

**Files:**
- Modify: `pulse/Views/AgentStatusManagementView.swift`
- Modify: `pulse/App/AppDelegate.swift`
- Create: `pulseTests/AgentStatusManagementViewTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing tests for selected-agent filtering**

```swift
import XCTest
@testable import Pulse

final class AgentStatusManagementViewTests: XCTestCase {
    func testSelectedAgentGroupReturnsOnlyMatchingGroup() {
        let groups = [
            AgentStatusGroup(agent: .openCode, slots: [makeSlot(agent: .openCode, state: .working)], overflowCount: 0),
            AgentStatusGroup(agent: .codex, slots: [makeSlot(agent: .codex, state: .idle)], overflowCount: 0)
        ]

        XCTAssertEqual(
            AgentStatusManagementView.visibleGroups(groups, selectedAgent: .codex).map(\.agent),
            [.codex]
        )
    }
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentStatusManagementViewTests`

Expected: FAIL with missing selected-agent filtering helper.

- [ ] **Step 3: Add selected-agent filtering support to `AgentStatusManagementView`**

```swift
struct AgentStatusManagementView: View {
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    @EnvironmentObject var agentIntegrationManager: AgentIntegrationManager
    let selectedAgent: AgentStatusAgent

    static func visibleGroups(
        _ groups: [AgentStatusGroup],
        selectedAgent: AgentStatusAgent
    ) -> [AgentStatusGroup] {
        groups.filter { $0.agent == selectedAgent }
    }
}
```

- [ ] **Step 4: Render only the selected group and update the header copy**

```swift
var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            header

            ForEach(Self.visibleGroups(agentStatusStore.groups, selectedAgent: selectedAgent)) { group in
                groupSection(group)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(selectedAgent.displayName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text("Review this agent's live sessions and integration status.")
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)
    }
}
```

- [ ] **Step 5: Update `AppDelegate` panel creation to inject the selected agent**

```swift
private func makeAgentStatusPanel() -> InputPanel {
    let panel = InputPanel(...)
    panel.contentViewController = makeAgentStatusHostingController()
    return panel
}

private func makeAgentStatusHostingController() -> NSHostingController<some View> {
    NSHostingController(
        rootView:
            AgentStatusManagementView(selectedAgent: selectedAgentStatusPanelAgent ?? .openCode)
                .environmentObject(agentStatusStore)
                .environmentObject(agentIntegrationManager)
                .environmentObject(themeManager)
                .id(selectedAgentStatusPanelAgent ?? .openCode)
    )
}
```

- [ ] **Step 6: Re-run the selected-agent tests and the full test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentStatusManagementViewTests`

Expected: PASS

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

Expected: TEST SUCCEEDED

- [ ] **Step 7: Commit the single-agent panel rendering**

```bash
git add pulse/Views/AgentStatusManagementView.swift pulse/App/AppDelegate.swift pulseTests/AgentStatusManagementViewTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: show one agent per status panel"
```

### Task 4: Polish menu bar and panel behavior

**Files:**
- Modify: `pulse/Views/MenuBarStatusItemView.swift`
- Modify: `pulse/App/AppDelegate.swift`

- [ ] **Step 1: Brighten the overflow marker and ensure hit regions refresh with layout updates**

```swift
private func drawOverflow(_ count: Int, at center: NSPoint) {
    let text = "+\(count)"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
        .foregroundColor: NSColor.labelColor
    ]
    ...
}

private func render(...) {
    ...
    recalculateGroupRegions()
    toolTip = accessibilityLabel()
    needsDisplay = true
}
```

- [ ] **Step 2: Ensure hidden selected agents close the panel instead of showing stale content**

```swift
private func updateAgentStatusItemVisibility() {
    let enabledAgents = Set(agentLightsSettings.enabledAgents)
    if let selected = selectedAgentStatusPanelAgent, enabledAgents.contains(selected) == false {
        closeAgentStatusPanel()
        selectedAgentStatusPanelAgent = nil
    }
    ...
}
```

- [ ] **Step 3: Build and manually verify the interaction flow**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`

Expected: BUILD SUCCEEDED

Manual verification:
- Click the OpenCode icon-plus-lights group and confirm only OpenCode content appears
- Click the Codex icon-plus-lights group while the panel is open and confirm the content switches in place
- Click the `+1` overflow label and confirm it still opens that agent’s content
- Disable one agent in settings and confirm its panel content no longer stays open

- [ ] **Step 4: Commit the interaction polish**

```bash
git add pulse/Views/MenuBarStatusItemView.swift pulse/App/AppDelegate.swift
git commit -m "style: polish per-agent panel interactions"
```

## Self-Review

- Spec coverage: The plan covers click-zone grouping, single-panel switching, one-agent-only rendering, overflow inclusion, and hidden-agent behavior.
- Placeholder scan: No `TODO` or undefined implementation placeholders remain; each task includes concrete files, commands, and code shape.
- Type consistency: The plan consistently uses `selectedAgentStatusPanelAgent`, `onLeftClickAgent`, `onRightClickAgent`, `agent(at:)`, and `visibleGroups(_:selectedAgent:)`.
