# Agent Usage Refresh Interval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users configure the background Agent Usage refresh interval from Settings while keeping 30 minutes as the default.

**Architecture:** Add a persisted interval configuration to `AgentUsageSettings`, surface it conditionally in the existing Agent Usage settings section, and make the existing `AppDelegate` scheduler reconfigurable. When a valid interval changes while enabled, cancel and replace the repeating schedule without triggering an immediate refresh.

**Tech Stack:** Swift 5.9+, SwiftUI, Combine, Foundation `UserDefaults`, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-26-agent-usage-refresh-interval-design.md`

## Global Constraints

- Keep 30 minutes as the default.
- Offer 30 seconds, 1 minute, 10 minutes, 30 minutes, and Custom.
- For Custom, accept a positive whole-number amount and a seconds, minutes, or hours unit.
- Keep scheduled refreshes running in the background while Agent Usage is enabled, including while the panel is closed.
- Do not change manual refresh, refresh-on-panel-open, or refresh-on-tab-entry behavior.
- Do not add a separate auto-refresh enable/disable toggle.
- Show Auto-refresh controls only while Enable Agent Usage is on.
- Retain the resizable Settings window and its 520×280 minimum; do not add a conflicting fixed outer frame.

## Review Focus

- Missing or malformed stored preference resolves to 30 minutes — test in Task 1.
- Each preset resolves to its exact duration (30, 60, 600, or 1,800 seconds) — test in Task 1.
- Custom seconds/minutes/hours resolve correctly and survive a settings reload — test in Task 1.
- Zero or invalid custom values never reach the scheduler — test in Task 1 and Task 2.
- Changing a valid interval while enabled cancels the old schedule, schedules the new interval, and does not refresh immediately — test in Task 2.

---

### Task 1: Persist and resolve Agent Usage refresh intervals

**Files:**
- Modify: `pulse/Managers/AgentUsageSettings.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Produce `AgentUsageRefreshIntervalChoice` with `seconds30`, `minute1`, `minutes10`, `minutes30`, and `custom` cases.
- Produce `AgentUsageRefreshIntervalUnit` with `seconds`, `minutes`, and `hours` cases.
- Produce `AgentUsageRefreshInterval` with `choice`, `customAmount`, `customUnit`, and a `resolvedTimeInterval: TimeInterval?` computed property. A nonpositive custom amount resolves to `nil`.
- Add `@Published var autoRefreshInterval: AgentUsageRefreshInterval` to `AgentUsageSettings`; default it to 30 minutes and persist/restore it through the injected `UserDefaults`.

- [x] **Step 1: Write failing settings tests** in `AgentUsageStoreTests.swift` for the 30-minute default when no preference exists or stored values are malformed, all four preset durations, custom conversion for each unit, custom value/unit persistence through a second settings instance, and an invalid nonpositive custom amount resolving to `nil`.
- [x] **Step 2: Run the focused tests and verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`

Expected: the new tests fail because the interval model and settings property do not exist yet.

- [x] **Step 3: Implement the interval choices, units, resolved duration, and UserDefaults persistence** in `AgentUsageSettings.swift`. If stored values are missing or malformed, initialize to the 30-minute default; never resolve a nonpositive custom amount to a timer interval.
- [x] **Step 4: Run the focused tests and verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`

Expected: all `AgentUsageStoreTests` pass, including the new interval tests.

- [x] **Step 5: Commit this task**

```bash
git add pulse/Managers/AgentUsageSettings.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: persist agent usage refresh interval"
```

### Task 2: Make the background scheduler reconfigurable

**Files:**
- Modify: `pulse/App/AppDelegate.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Add `func setInterval(_ interval: TimeInterval)` to `AgentUsageRefreshScheduler`. Ignore non-finite or nonpositive values. If the interval changes while enabled, cancel and replace the repeating schedule without calling the refresh closure immediately.
- Keep `setEnabled(_:)` behavior: enabling schedules once; disabling cancels; no refresh while disabled.

- [x] **Step 1: Write a failing scheduler test** asserting that changing an enabled scheduler from 1,800 to 30 seconds cancels the original schedule, schedules the replacement at 30 seconds, does not immediately refresh, and invokes refresh only when the replacement callback runs. Also assert a nonpositive interval does not replace a valid schedule.
- [x] **Step 2: Run the focused scheduler test and verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`

Expected: the test fails because `setInterval(_:)` is not implemented.

- [x] **Step 3: Implement `setInterval(_:)`** in `AgentUsageRefreshScheduler`, keeping the scheduler’s existing cancellation and enabled-state behavior.
- [x] **Step 4: Run the focused scheduler test and verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`

Expected: the new reconfiguration test and existing scheduler test pass.

- [x] **Step 5: Commit this task**

```bash
git add pulse/App/AppDelegate.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: reconfigure agent usage refresh scheduler"
```

### Task 3: Add the setting to Settings and connect it to the scheduler

**Files:**
- Modify: `pulse/Views/SettingsView.swift`
- Modify: `pulse/App/AppDelegate.swift`

**Interfaces:**
- Use `AgentUsageSettings.autoRefreshInterval` from Task 1 for the interval choice and custom amount/unit bindings.
- Use `AgentUsageRefreshScheduler.setInterval(_:)` from Task 2 when `autoRefreshInterval.resolvedTimeInterval` changes.

- [x] **Step 1: Add an Auto-refresh subsection** to `agentUsageContent` in `SettingsView.swift`. Render it only when `agentUsageSettings.isEnabled` is true. Include the four preset choices and Custom; show the numeric amount and unit controls only for Custom. Keep controls in the existing Agent Usage section and follow the existing SwiftUI styles.
- [x] **Step 2: Connect interval changes to the existing scheduler** in `AppDelegate.setupFeatureObservation()`. On a valid interval change, call `setInterval(_:)`; preserve the existing enable/source observation and panel-layout behavior. Initialize the scheduler from the saved interval, falling back to 30 minutes.
- [x] **Step 3: Run the complete test suite and verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`

Expected: the test command succeeds, including the preference and scheduler regression tests.

- [x] **Step 4: Commit this task**

```bash
git add pulse/Views/SettingsView.swift pulse/App/AppDelegate.swift
git commit -m "feat: add agent usage refresh interval setting"
```
