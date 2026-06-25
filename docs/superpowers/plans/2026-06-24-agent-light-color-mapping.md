# Agent Light Color Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralize agent light colors so every agent uses the same mapping, with `working` shown in green and `idle` shown in yellow everywhere.

**Architecture:** Add one shared AppKit-backed color helper near the agent status domain and make both current renderers consume it instead of hardcoded colors. Keep session-state semantics unchanged, and cover the swap with focused unit tests plus the normal macOS build/test verification.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, XCTest, Xcode project file updates

---

## File Structure

- Create: `pulse/Managers/AgentSessionLightColor.swift`
  - Shared presentation helper for mapping `AgentSessionLightState` to an `NSColor`
  - Lightweight SwiftUI bridge so SwiftUI views can consume the same mapping
- Modify: `pulse/Views/MenuBarStatusItemView.swift`
  - Replace hardcoded menu bar light fills with the shared mapping
- Modify: `pulse/Views/AgentStatusManagementView.swift`
  - Replace hardcoded panel light colors with the shared mapping
- Modify: `pulseTests/MenuBarStatusItemViewTests.swift`
  - Add direct coverage for shared menu bar mapping expectations
- Modify: `pulseTests/AgentStatusManagementViewTests.swift`
  - Add direct coverage for shared panel mapping expectations
- Modify: `pulse.xcodeproj/project.pbxproj`
  - Add the new Swift source file to the `pulse` target and keep project references valid

### Task 1: Add Failing Color-Mapping Tests

**Files:**
- Modify: `pulseTests/MenuBarStatusItemViewTests.swift`
- Modify: `pulseTests/AgentStatusManagementViewTests.swift`

- [ ] **Step 1: Add a failing menu bar color test**

```swift
@MainActor
func testLightColorMapsWorkingToGreenAndIdleToYellow() {
    XCTAssertEqual(
        MenuBarStatusItemView.color(for: .working),
        NSColor.systemGreen
    )
    XCTAssertEqual(
        MenuBarStatusItemView.color(for: .idle),
        NSColor.systemYellow
    )
}
```

- [ ] **Step 2: Add a failing management-view color test**

```swift
func testLightColorMapsWorkingToGreenAndIdleToYellow() {
    XCTAssertEqual(
        AgentStatusManagementView.color(for: .working),
        .green
    )
    XCTAssertEqual(
        AgentStatusManagementView.color(for: .idle),
        .yellow
    )
}
```

- [ ] **Step 3: Run the focused tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/MenuBarStatusItemViewTests -only-testing:pulseTests/AgentStatusManagementViewTests
```

Expected:

```text
Test suite 'MenuBarStatusItemViewTests' started
Test suite 'AgentStatusManagementViewTests' started
... error: type 'MenuBarStatusItemView' has no member 'color'
... error: type 'AgentStatusManagementView' has no member 'color'
** TEST FAILED **
```

- [ ] **Step 4: Commit the failing-test checkpoint**

```bash
git add pulseTests/MenuBarStatusItemViewTests.swift pulseTests/AgentStatusManagementViewTests.swift
git commit -m "test: add agent light color mapping expectations"
```

### Task 2: Implement Shared Agent Light Colors

**Files:**
- Create: `pulse/Managers/AgentSessionLightColor.swift`
- Modify: `pulse/Views/MenuBarStatusItemView.swift`
- Modify: `pulse/Views/AgentStatusManagementView.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the shared mapping helper**

Create `pulse/Managers/AgentSessionLightColor.swift` with:

```swift
import AppKit
import SwiftUI

enum AgentSessionLightColor {
    static func nsColor(for state: AgentSessionLightState) -> NSColor {
        switch state {
        case .empty:
            return .separatorColor
        case .working:
            return .systemGreen
        case .idle:
            return .systemYellow
        case .error:
            return .systemRed
        }
    }

    static func swiftUIColor(for state: AgentSessionLightState) -> Color {
        Color(nsColor: nsColor(for: state))
    }
}
```

- [ ] **Step 2: Wire the new file into Xcode**

Update `pulse.xcodeproj/project.pbxproj` so the new file appears alongside the other `pulse/Managers/*.swift` files in the `pulse` target sources list.

Use the existing nearby manager-file entries as the pattern:

```pbxproj
<new file reference for AgentSessionLightColor.swift>
<new build file for AgentSessionLightColor.swift in Sources>
```

- [ ] **Step 3: Update the menu bar view to consume the shared mapping**

In `pulse/Views/MenuBarStatusItemView.swift`, replace the hardcoded fill switch with:

```swift
private func drawLight(_ state: AgentSessionLightState, at center: NSPoint) {
    let rect = NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
    let path = NSBezierPath(ovalIn: rect)

    switch state {
    case .empty:
        AgentSessionLightColor.nsColor(for: state).setStroke()
        path.lineWidth = 1
        path.stroke()
    default:
        AgentSessionLightColor.nsColor(for: state).setFill()
        path.fill()
    }
}
```

Also add a DEBUG-only test seam near the existing test helpers:

```swift
static func color(for state: AgentSessionLightState) -> NSColor {
    AgentSessionLightColor.nsColor(for: state)
}
```

- [ ] **Step 4: Update the management view to consume the shared mapping**

In `pulse/Views/AgentStatusManagementView.swift`, replace the current `color(for:)` body with:

```swift
static func color(for state: AgentSessionLightState) -> Color {
    AgentSessionLightColor.swiftUIColor(for: state)
}

private func color(for state: AgentSessionLightState) -> Color {
    Self.color(for: state)
}
```

This keeps the existing call sites intact while exposing a stable test seam.

- [ ] **Step 5: Run the focused tests to verify they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/MenuBarStatusItemViewTests -only-testing:pulseTests/AgentStatusManagementViewTests
```

Expected:

```text
Test suite 'MenuBarStatusItemViewTests' passed
Test suite 'AgentStatusManagementViewTests' passed
** TEST SUCCEEDED **
```

- [ ] **Step 6: Commit the implementation checkpoint**

```bash
git add pulse/Managers/AgentSessionLightColor.swift pulse/Views/MenuBarStatusItemView.swift pulse/Views/AgentStatusManagementView.swift pulse.xcodeproj/project.pbxproj pulseTests/MenuBarStatusItemViewTests.swift pulseTests/AgentStatusManagementViewTests.swift
git commit -m "refactor: centralize agent light colors"
```

### Task 3: Full Verification

**Files:**
- Modify: none
- Verify: existing workspace state remains intact after build/test

- [ ] **Step 1: Run the full macOS test suite**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
```

Expected:

```text
Testing started
Test suite 'pulseTests.xctest' passed
** TEST SUCCEEDED **
```

- [ ] **Step 2: Run a debug build**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected:

```text
Build settings from command line
...
** BUILD SUCCEEDED **
```

- [ ] **Step 3: Manually verify the swapped lights in both surfaces**

Check:

```text
1. A working OpenCode or Codex session renders green in the menu bar.
2. An idle OpenCode or Codex session renders yellow in the menu bar.
3. The same sessions render the same colors in the Agent Status panel.
4. Empty and error states still look unchanged apart from using the shared helper.
```

- [ ] **Step 4: Commit the verification checkpoint**

```bash
git add .
git commit -m "test: verify agent light color mapping"
```
