# Launch at Login

Date: 2026-08-18

## Problem

Pulse is a menu bar app that users keep running in the background. Today it must be
launched manually after each computer restart. This spec adds a "Launch at Login"
option so Pulse starts automatically when the user logs in.

## Goal

- A "Launch at Login" toggle in Settings that controls whether Pulse starts at login.
- A new "General" Settings section that contains the toggle and absorbs the existing
  Theme picker.

## Non-Goals

- No helper login-item bundle (e.g. a `LoginItems/` helper app).
- No manual `~/Library/LaunchAgents` plist management.
- No per-user vs. system-wide launch choices; login-item scope only.

## Approach

Use the modern macOS ServiceManagement API: `SMAppService.mainApp` (macOS 13+;
Pulse targets macOS 14+). Registering the main app itself as a login item makes it
appear in System Settings → General → Login Items alongside any normal app. No
helper bundle or plist files are involved.

The app is already a background-only app (`LSUIElement = true`), which is exactly the
kind of app this API is designed for.

## Architecture

### `pulse/Managers/LaunchAtLoginSettings.swift` (new)

An `ObservableObject` store following the existing `AgentLightsSettings` pattern:

```swift
final class LaunchAtLoginSettings: ObservableObject {
    @Published var isEnabled: Bool
    @Published var errorMessage: String?
    // ...
}
```

- `isEnabled` is persisted to `UserDefaults` under key `general.launchAtLogin`.
- Setting `isEnabled = true` calls `SMAppService.mainApp.register()`;
  `isEnabled = false` calls `SMAppService.mainApp.unregister()`.
- The actual `SMAppService.mainApp.status` is the source of truth. `refresh()`
  re-syncs `isEnabled` from `status == .enabled` and clears stale errors.
- `SMAppService` is hidden behind a small injectable protocol so unit tests can mock
  registration:

```swift
protocol LaunchAtLoginService {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}
```

- Default implementation wraps `SMAppService.mainApp` (import `ServiceManagement`).

### `pulse/App/AppDelegate.swift`

- Add `private let launchAtLoginSettings = LaunchAtLoginSettings()`.
- Call `launchAtLoginSettings.refresh()` in `applicationDidFinishLaunching` and when
  `showSettings()` runs (so toggling the login item in System Settings while Pulse is
  running stays reflected).
- Inject `launchAtLoginSettings` as an environment object in `makeSettingsWindow()`.

### `pulse/Views/SettingsView.swift`

- Rename the sidebar section `theme` → `general`; add sidebar button
  "General" (`gearshape` icon) as the first item.
- `generalContent` renders:
  1. "General" heading.
  2. "Launch at Login" toggle (`Toggle("Launch at Login", isOn: $launchAtLoginSettings.isEnabled)`, `.switch` style) with a one-line description.
  3. Inline red error text when `errorMessage` is non-nil (matches the `UpdateManager`
     failure presentation style).
  4. The existing Theme picker block, unchanged.
- Add `@EnvironmentObject var launchAtLoginSettings: LaunchAtLoginSettings`.

## Error Handling

- `SMAppService.register()`/`unregister()` can throw (e.g. app not in a launchable
  location). On failure: revert `isEnabled` to the pre-toggle value and set
  `errorMessage` to a short human-readable string.
- `errorMessage` is cleared on the next successful toggle or `refresh()`.

## Edge Cases

- **Toggled in System Settings while Pulse is running**: `refresh()` on
  `applicationDidFinishLaunching` and `showSettings()` re-syncs the toggle from real
  status, so the checkbox always reflects reality.
- **App moved/relocated**: registration may fail or not persist; the inline error or
  the System Settings state surfaces this.
- **App killed during registration**: next launch `refresh()` re-syncs from real
  status.

## Testing

- Unit tests for `LaunchAtLoginSettings` using a mock `LaunchAtLoginService`:
  - initial state from `UserDefaults`
  - enable → `register()` called, `isEnabled` true
  - disable → `unregister()` called, `isEnabled` false
  - register throws → `isEnabled` reverts, `errorMessage` set
  - `refresh()` syncs from service status and clears stale errors
  - persistence round-trip through `UserDefaults`
- Existing suite must keep passing: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`.

## File Changes

| File | Change |
| --- | --- |
| `pulse/Managers/LaunchAtLoginSettings.swift` | new store + service protocol |
| `pulse/App/AppDelegate.swift` | own store, inject into Settings, `refresh()` calls |
| `pulse/Views/SettingsView.swift` | General section, toggle, error line |
| `pulseTests/LaunchAtLoginSettingsTests.swift` | new tests |
| `pulse.xcodeproj/project.pbxproj` | register new source/test files |