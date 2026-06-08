# Theme Settings Design

## Goal

Add first-class theme switching to Pulse through a dedicated settings window opened from the menu bar app's right-click context menu. The settings UI should start with a Theme section and be structured so future settings sections can be added without redesigning the window.

## Current State

- `ThemeManager` and `SettingsView` already exist, but `AppDelegate` does not instantiate or inject `ThemeManager`.
- `AppDelegate.makePanel()` hard-codes `.darkAqua` on both the `InputPanel` and hosting view.
- The menu bar item's right-click menu currently exposes only `Open`/`Close` and `Quit Pulse`.
- Several SwiftUI views use hard-coded `.white.opacity(...)` colors, so forcing `.aqua` alone would make light mode incomplete or unreadable.

## Interaction Model

- Left-clicking the menu bar icon keeps the current behavior: open or close the monitor panel.
- Right-clicking the menu bar icon opens a context menu with:
  - `Open` or `Close`
  - `Settings...`
  - separator
  - `Quit Pulse`
- `Settings...` opens a standalone settings window. It must work whether or not the main monitor panel is currently open.
- The settings window uses a two-pane layout:
  - left sidebar for settings sections
  - right content area for the selected section
- The initial sidebar contains one section: `Theme`.
- The Theme content area presents `System`, `Dark`, and `Light` choices.

## Theme Behavior

- `ThemeManager` remains the single source of truth for the selected theme.
- `AppDelegate` owns one persistent `ThemeManager` instance, similar to the existing `SystemMonitor` instance.
- `ThemeManager` is injected into SwiftUI views with `.environmentObject(themeManager)`.
- Selecting a theme updates immediately and persists through the existing `UserDefaults` key: `"appTheme"`.
- `System` maps to `nil` appearance so macOS controls light/dark.
- `Dark` maps to `.darkAqua`.
- `Light` maps to `.aqua`.
- The selected appearance is applied to both the main monitor panel and the settings window.

## UI Structure

- Replace the current single-purpose `SettingsView` body with a two-pane structure.
- Use a small local sidebar selection enum, initially with one case: `.theme`.
- The right pane switches on the selected sidebar item and renders a `ThemeSettingsView`-style subview or equivalent inline section.
- Avoid overbuilding future settings infrastructure. The design only needs a clear extension point, not a plugin system or separate settings registry.

## Theme-Aware Colors

- Add a small semantic color layer in `Colors.swift` or a nearby view helper.
- Replace hard-coded text and divider colors where they affect light-mode readability.
- Suggested semantic roles:
  - primary text
  - secondary text
  - tertiary text
  - divider
  - field background
  - subtle border
- Existing metric accent colors can remain unchanged because they are semantic status/accent colors rather than theme background colors.

## AppKit Window Management

- Add settings window state to `AppDelegate`, likely `private var settingsWindow: NSWindow?`.
- Add a `showSettings()` action used by the context menu's `Settings...` item.
- Reuse the existing activation-policy pattern so the settings window can become key without leaving a Dock icon visible:
  - temporarily switch to `.regular`
  - activate the app and show the window
  - return to `.accessory` asynchronously
- Do not change `LSUIElement = true`.

## Non-Goals

- Do not add a Theme submenu to the right-click menu.
- Do not add settings into the main monitor panel as a third tab.
- Do not add external dependencies.
- Do not add persistence beyond the selected theme.
- Do not add additional settings sections in this change.

## Verification

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Manual checks after launch:

- Right-click menu contains `Settings...`.
- Settings window opens when the main monitor panel is closed.
- Settings window opens when the main monitor panel is open.
- Selecting `System`, `Dark`, or `Light` updates visible app windows immediately.
- Theme selection survives relaunch.
- Text and dividers remain readable in light mode.
- Opening the monitor panel or settings window does not leave a Dock icon visible.
