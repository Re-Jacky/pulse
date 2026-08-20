# Keep Awake

Date: 2026-08-20

## Problem

Pulse is a menu bar app that users keep running in the background. Sometimes users
need their Mac to stay awake — running long builds, downloads, or presentations —
but don't want to install a separate utility like KeepingYouAwake. This spec adds a
built-in "Keep Awake" feature directly into Pulse.

## Goal

- Two Keep Awake modes: **Smart** (agent-aware) and **Manual** (force-on).
- Smart mode automatically prevents sleep while agents are working, and releases
  after a 5-minute idle cooldown.
- Manual mode keeps the Mac awake indefinitely or for a set timer duration.
- Display-sleep-only option for both modes.
- Visual feedback on the status bar icon when Keep Awake is active.
- A quick-access toggle in the right-click context menu.

## Non-Goals

- No battery threshold monitoring (deactivating when battery drops below a level).
- No external display auto-activation.
- No Low Power Mode detection.
- No configurable idle delay — fixed at 5 minutes.
- No menu bar extra icon overlay/badge — a simple icon swap is sufficient.

## Background: Sleep Prevention on macOS

macOS provides two independent sleep concepts:

- **System idle sleep** — the Mac itself sleeps (CPU, disk, network pause).
- **Display idle sleep** — just the screen turns off, but the system keeps running.

The `IOPMAssertion` API from `IOKit` controls both:

| Assertion Type | Effect |
|---|---|
| `kIOPMAssertionTypePreventUserIdleSystemSleep` | System stays awake; display CAN still dim/turn off |
| `kIOPMAssertionTypePreventUserIdleDisplaySleep` | Display stays awake; system CAN still sleep |

KeepingYouAwake wraps `/usr/bin/caffeinate`, which itself calls these same
`IOPMAssertion` APIs. We call them directly — no subprocess needed.

## Approach

Use `IOPMAssertionCreateWithName` / `IOPMAssertionRelease` from `IOKit` directly.
No entitlements required — these APIs work for any macOS app.

Persist settings to `UserDefaults`. On launch, restore state: if Manual mode was
active, re-create the assertion; if Smart mode was active, re-enter smart monitoring
(will assert on next `.working` event).

## Architecture

### Mode Definitions

| Mode | Behavior | Availability |
|---|---|---|
| **Smart** | Monitors `AgentStatusStore` groups. Asserts on any `.working` slot. Releases after all slots are `.idle`/`.empty` for 5 minutes. | Only when Agent Lights is enabled AND at least one agent integration is installed. |
| **Manual** | Always asserts (force-on). Optionally with a timer. | Always available. |

Only one mode can be active at a time. Switching modes deactivates the current mode
before activating the new one.

### Smart Mode Availability

Smart mode is available when ALL of the following are true:

1. `agentLightsSettings.isEnabled == true`
2. `agentIntegrationManager.status(for: .openCode).state` is `.installedNeedsRestart`
   or `.installedNeedsActivation` — OR —
   `agentIntegrationManager.status(for: .codex).state` is one of those values.
   (At least one agent integration must be installed.)

If Agent Lights is disabled or no agents are installed while Smart mode is selected,
the UI disables the Smart option and falls back to Manual.

### `pulse/Managers/KeepAwakeSettings.swift` (new)

An `ObservableObject` store following the existing `LaunchAtLoginSettings` pattern:

```swift
final class KeepAwakeSettings: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case smart, manual
        var id: String { rawValue }
        var label: String { switch self { case .smart: "Smart"; case .manual: "Manual" } }
    }

    enum TimerDuration: CaseIterable, Identifiable {
        case indefinite, m30, h1, h2, h5
        var id: String { rawValue }
        var label: String { /* display text */ }
        var interval: TimeInterval? { /* seconds, nil = indefinite */ }
    }

    @Published var mode: Mode
    @Published var displaySleepOnly: Bool
    @Published var timerDuration: TimerDuration

    private var assertionID: IOPMAssertionID = 0
    private var timerWorkItem: DispatchWorkItem?
    private var smartIdleWorkItem: DispatchWorkItem?
    private var isSmartAsserted = false
}
```

**Dependencies (injected at init):**

- `agentStatusStore: AgentStatusStore` — to observe agent working/idle states.
- `agentLightsSettings: AgentLightsSettings` — to check if Agent Lights is enabled.
- `agentIntegrationManager: AgentIntegrationManager` — to check if agents are installed.

**UserDefaults keys:**

| Key | Type | Default |
|---|---|---|
| `general.keepAwake.mode` | `String` (raw value) | `"manual"` |
| `general.keepAwake.displaySleepOnly` | `Bool` | `false` |
| `general.keepAwake.timerDuration` | `String` (raw value) | `"indefinite"` |
| `general.keepAwake.timerEndDate` | `Double` (epoch) | `0` |

**Core methods:**

- `apply()` — called whenever any published property changes.
  - If `mode == .manual`: creates/updates the assertion (or releases if timer expired).
  - If `mode == .smart`: enters smart monitoring mode (asserts on next `.working`).
- `activate()` — creates the IOPMAssertion and schedules timer (if Manual).
- `deactivate()` — releases the assertion, cancels all timers.
- `restoreIfNeeded()` — called on launch. Restores Manual assertion or re-enters
  smart monitoring based on persisted mode.
- `isSmartAvailable` — computed property: checks `agentLightsSettings.isEnabled`
  and `agentIntegrationManager` status for at least one installed agent.

**Smart mode monitoring:**

- Observe `agentStatusStore.$groups` via Combine.
- When any slot across all groups has `state == .working`: call `activate()` and
  cancel any pending idle timer.
- When all slots are `.idle` or `.empty`: start a 5-minute idle timer.
- When the idle timer fires: call `deactivate()`.
- `smartIdleWorkItem` tracks the pending idle timer so it can be cancelled on new
  `.working` events.

**Timer behavior (Manual mode):**

- When a timed activation starts, store `timerEndDate = Date() + duration` in
  UserDefaults.
- Schedule a `DispatchWorkItem` on the main queue for the remaining time.
- On expiry: call `deactivate()`, which releases the assertion and persists off.
- On launch with a future `timerEndDate`: compute remaining time, schedule the work
  item.
- Manual disable at any time cancels the timer and releases the assertion.

**Icon update callback:**

- `onIsActiveChange: ((Bool) -> Void)?` — called whenever the assertion is created
  or released (regardless of mode). AppDelegate observes this to swap the status
  bar icon.

### `pulse/App/AppDelegate.swift`

- Add `private lazy var keepAwakeSettings = KeepAwakeSettings(...)`.
- In `applicationDidFinishLaunching`: call `keepAwakeSettings.restoreIfNeeded()`.
- Observe `keepAwakeSettings.onIsActiveChange` (or a published `isActive` property)
  to update the status bar icon:
  - `true` → `NSImage(systemSymbolName: "cpu.fill", ...)`
  - `false` → `NSImage(systemSymbolName: "cpu", ...)`
- Inject `keepAwakeSettings` as an environment object in `makeSettingsWindow()`.
- In `showContextMenu()`: add a "Keep Awake" menu item with a checkmark when
  active. Toggling it on uses the current mode and settings from the Settings
  window — no duplicate config in the menu.

### `pulse/Views/SettingsView.swift`

Add to the General section, below the Launch at Login toggle:

1. **"Keep Awake"** section header.
2. **Mode picker** — two options: "Smart" and "Manual". "Smart" is disabled (grayed
   out) when Agent Lights is not enabled or no agents are installed, with a tooltip
   explaining why.
3. **"Allow display to sleep"** sub-toggle — visible for both modes. Description:
   "Keep system awake but allow the screen to dim."
4. **Timer picker** — only visible when Manual mode is selected. A row of buttons:
   Indefinite, 30 min, 1 hr, 2 hr, 5 hr. "Indefinite" is the default.
5. **Smart mode status line** — only visible when Smart mode is selected. Shows
   "Monitoring agents..." when agents are working, or "Waiting for agent activity..."
   when idle. This is informational only.

Add `@EnvironmentObject var keepAwakeSettings: KeepAwakeSettings`.

## Error Handling

- `IOPMAssertionCreateWithName` returns `kIOReturnSuccess` on success. If it fails
  (unlikely for these assertion types), revert state and log the error.
- No user-facing error UI needed — assertion creation for idle sleep is a
  well-supported, non-privileged API.

## Edge Cases

- **App quit while Keep Awake is on**: the assertion is automatically released when
  the process exits (IOKit cleans up per-process assertions). On next launch,
  `restoreIfNeeded()` re-creates state from persisted settings.
- **System sleep initiated by user (lid close, Apple menu)**: `IOPMAssertion` only
  prevents idle sleep — forced sleep (lid close, Apple menu Sleep) still works. This
  is correct behavior.
- **Timer expires while app is not running (Manual)**: on next launch,
  `restoreIfNeeded()` checks `timerEndDate` — if in the past, deactivates
  immediately.
- **Agent goes idle during Manual mode**: Manual mode ignores agent status entirely.
  The assertion stays held until the timer expires or the user disables it.
- **Agent goes working during Smart mode idle timer**: the idle timer is cancelled
  and the assertion stays held.
- **Switching from Smart to Manual**: deactivate smart monitoring, then activate
  manual assertion. vice versa.
- **Agent Lights disabled while Smart mode is active**: deactivate Keep Awake, fall
  back to Manual mode.
- **Multiple toggles in quick succession**: each `apply()` call releases the old
  assertion and creates a new one if needed. No accumulated assertions.

## Testing

- Unit tests for `KeepAwakeSettings`:
  - Initial state from `UserDefaults`
  - Manual mode enable → assertion created
  - Manual mode disable → assertion released
  - Manual mode timer scheduling and expiry → auto-disable
  - Manual mode display sleep only → correct assertion type
  - Smart mode: agent `.working` event → assertion created
  - Smart mode: all agents `.idle` → 5-minute timer starts
  - Smart mode: timer fires → assertion released
  - Smart mode: new `.working` event during idle timer → timer cancelled
  - Smart mode: not available when Agent Lights disabled
  - Smart mode: not available when no agents installed
  - Mode switch → old mode deactivated, new mode activated
  - `restoreIfNeeded()` restores correct mode on launch
  - Persistence round-trip through `UserDefaults`
- Existing suite must keep passing:
  `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`.

## File Changes

| File | Change |
| --- | --- |
| `pulse/Managers/KeepAwakeSettings.swift` | new settings store with assertion logic, smart monitoring |
| `pulse/App/AppDelegate.swift` | own store, inject into Settings, icon swap, context menu items |
| `pulse/Views/SettingsView.swift` | General section: mode picker, display-sleep toggle, timer, status |
| `pulseTests/KeepAwakeSettingsTests.swift` | new tests |
| `pulse.xcodeproj/project.pbxproj` | register new source/test files |
