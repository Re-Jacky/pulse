# Distribution, Theme Switching, and Quit Menu — Design Spec

## Summary

Three features to add to pulse:

1. **DMG distribution** — a shell script that builds a Release `.app` and packages it into a `.dmg` using only `hdiutil` (no external tools)
2. **Theme switching** — a Preferences window with System / Dark / Light options, persisted via `UserDefaults`, applied live to the popover
3. **Right-click context menu** — menu bar icon right-click shows Open / Preferences… / Quit

---

## Feature 1: DMG Build Script

**Goal:** `scripts/build-dmg.sh` produces `dist/pulse-<version>.dmg` suitable for drag-to-install distribution.

**Approach:**
- `xcodebuild` builds the Release configuration
- `hdiutil` creates a writable DMG staging disk image
- The `.app` and a symlink to `/Applications` are copied in
- `hdiutil convert` converts to compressed read-only DMG
- Output lands in `dist/`

**No dependencies** — only Xcode + macOS built-ins required.

---

## Feature 2: Theme Switching

**Goal:** User can choose between System, Dark, and Light appearance. Choice persists across launches.

### ThemeManager

A standalone `ObservableObject` (`ThemeManager.swift`) that:
- Reads/writes `UserDefaults` key `"appTheme"` (values: `"system"`, `"dark"`, `"light"`)
- Exposes `currentTheme: AppTheme` (`enum AppTheme: String`)
- Exposes `nsAppearance: NSAppearance?` computed property used by AppDelegate to set view appearance

### Settings Window

- Opened by "Preferences…" in the context menu
- `NSWindow` (not a popover) — 260×130pt, non-resizable, title "Preferences"
- SwiftUI content via `NSHostingController`
- `SettingsView`: a `Picker` (segmented) with System / Dark / Light, bound to `ThemeManager`
- Window closes on "Done" button
- `AppDelegate` owns the window and `ThemeManager` instance

### Applying the theme

`AppDelegate` observes `ThemeManager.$currentTheme` via Combine and sets `popover.contentViewController?.view.appearance` accordingly. Also sets on the settings window itself.

---

## Feature 3: Right-Click Context Menu

**Goal:** Left-click opens/closes the popover as before. Right-click shows a context menu.

### Menu items
```
Open / Close
──────────────
Preferences…
──────────────
Quit pulse
```

### Implementation

`NSStatusItem` supports `menu` property, but setting it disables left-click `action`. Instead:

- Keep `button.action = #selector(handleClick)`  
- In `handleClick`, inspect `NSApp.currentEvent?.type`:
  - `.rightMouseUp` or modifier flags → show `NSMenu`
  - otherwise → toggle popover
- `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`

This is the standard pattern for dual-action status bar buttons.

---

## Constraints

- No external dependencies (no `create-dmg`, no Homebrew tools)
- `UserDefaults` only — no file-based persistence
- Settings window is a plain `NSWindow`, not a SwiftUI `Settings` scene (app has no `@main` SwiftUI lifecycle)
- `LSUIElement = true` stays — no Dock icon
