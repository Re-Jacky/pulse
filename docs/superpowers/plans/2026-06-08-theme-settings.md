# Theme Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right-click `Settings...` window with a left-side Theme tab and working System/Dark/Light theme switching.

**Architecture:** `AppDelegate` owns one `ThemeManager`, injects it into SwiftUI, observes changes, and applies the selected `NSAppearance` to open AppKit windows. `SettingsView` becomes a two-pane SwiftUI view that can grow additional settings sections later. Existing hard-coded dark text/divider colors are replaced with small semantic color helpers so light mode remains readable.

**Tech Stack:** Swift 5, AppKit, SwiftUI, Combine, UserDefaults, Xcode project `pulse.xcodeproj` scheme `pulse`.

---

## File Map

- Modify `pulse/App/AppDelegate.swift`: own `ThemeManager`, observe theme changes, inject it into `PopoverView`, create/show the settings window, and add `Settings...` to the right-click menu.
- Modify `pulse/Views/SettingsView.swift`: replace the compact one-control view with a two-pane settings view with a left Theme tab and right-side theme picker.
- Modify `pulse/Views/Colors.swift`: add theme-aware semantic color helpers used by views.
- Modify `pulse/Views/PopoverView.swift`: read semantic divider color.
- Modify `pulse/Views/MetricRowView.swift`: replace hard-coded dark text/bar colors with semantic helpers.
- Modify `pulse/Views/ProcessListView.swift`: replace hard-coded dark text/field/divider colors with semantic helpers.
- Modify `pulse/Views/ProcessRowView.swift`: replace hard-coded dark text colors with semantic helpers.
- Modify `pulse.xcodeproj/project.pbxproj`: bump `MARKETING_VERSION` from `1.1.1` to `1.2.0` because this is a new feature.

No new Swift files are required, so no Xcode Sources build phase changes are needed.

---

### Task 1: Wire ThemeManager Through AppDelegate

**Files:**
- Modify: `pulse/App/AppDelegate.swift`

- [ ] **Step 1: Add Combine and persistent app-level state**

At the top of `pulse/App/AppDelegate.swift`, add Combine:

```swift
import AppKit
import Combine
import SwiftUI
```

Inside `final class AppDelegate`, replace the property block with:

```swift
private var statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
private var panel: InputPanel?
private var settingsWindow: NSWindow?
private var eventMonitor: Any?
private var cancellables = Set<AnyCancellable>()
private let monitor = SystemMonitor()
private let themeManager = ThemeManager()
```

- [ ] **Step 2: Start theme observation on launch**

In `applicationDidFinishLaunching`, call `setupThemeObservation()` after `setupMainMenu()`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupMainMenu()
    setupThemeObservation()

    if let button = statusItem.button {
        button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
        button.image?.isTemplate = true
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
}
```

- [ ] **Step 3: Add theme application helpers**

Add these methods below `setupMainMenu()`:

```swift
private func setupThemeObservation() {
    themeManager.$currentTheme
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.applyCurrentTheme()
        }
        .store(in: &cancellables)
}

private func applyCurrentTheme() {
    let appearance = themeManager.currentTheme.nsAppearance
    panel?.appearance = appearance
    panel?.contentViewController?.view.appearance = appearance
    settingsWindow?.appearance = appearance
    settingsWindow?.contentViewController?.view.appearance = appearance
}
```

- [ ] **Step 4: Inject ThemeManager into the main panel and remove hard-coded dark appearance**

In `makePanel()`, replace:

```swift
p.appearance = NSAppearance(named: .darkAqua)
```

with:

```swift
p.appearance = themeManager.currentTheme.nsAppearance
```

Replace the `NSHostingController` creation block:

```swift
let vc = NSHostingController(rootView: PopoverView().environmentObject(monitor))
vc.view.appearance = NSAppearance(named: .darkAqua)
p.contentViewController = vc
```

with:

```swift
let vc = NSHostingController(
    rootView: PopoverView()
        .environmentObject(monitor)
        .environmentObject(themeManager)
)
vc.view.appearance = themeManager.currentTheme.nsAppearance
p.contentViewController = vc
```

- [ ] **Step 5: Build to catch wiring errors**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: build succeeds. If it fails, errors should be limited to syntax/import issues in `AppDelegate.swift`; fix those before continuing.

---

### Task 2: Add Settings Window From Right-Click Menu

**Files:**
- Modify: `pulse/App/AppDelegate.swift`

- [ ] **Step 1: Add Settings menu item**

In `showContextMenu()`, after adding the `Open`/`Close` item and before the separator, insert:

```swift
let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
settingsItem.target = self
menu.addItem(settingsItem)
```

The method should have this shape:

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
    let quitItem = NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
}
```

- [ ] **Step 2: Add `showSettings()`**

Add this method before `showContextMenu()`:

```swift
@objc private func showSettings() {
    let window: NSWindow
    if let existing = settingsWindow {
        window = existing
    } else {
        let vc = NSHostingController(
            rootView: SettingsView()
                .environmentObject(themeManager)
        )
        vc.view.appearance = themeManager.currentTheme.nsAppearance

        let created = NSWindow(contentViewController: vc)
        created.title = "Settings"
        created.setContentSize(NSSize(width: 520, height: 320))
        created.minSize = NSSize(width: 460, height: 260)
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.isReleasedWhenClosed = false
        created.center()
        created.appearance = themeManager.currentTheme.nsAppearance
        settingsWindow = created
        window = created
    }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 3: Build to expose SettingsView signature mismatch**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: build may fail because current `SettingsView` requires `onDone`. Continue to Task 3 to replace that view.

---

### Task 3: Replace SettingsView With Two-Pane Layout

**Files:**
- Modify: `pulse/Views/SettingsView.swift`

- [ ] **Step 1: Replace the file with the two-pane settings view**

Replace all contents of `pulse/Views/SettingsView.swift` with:

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedSection: SettingsSection = .theme

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case theme

        var id: String { rawValue }

        var title: String {
            switch self {
            case .theme: return "Theme"
            }
        }

        var systemImage: String {
            switch self {
            case .theme: return "paintbrush"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 150)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 520, height: 320)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedSection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .theme:
            themePane
        }
    }

    private var themePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Choose how Pulse appears on this Mac.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Picker("Theme", selection: $themeManager.currentTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Text("System follows the current macOS appearance. Dark and Light force Pulse to that appearance.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
    }
}
```

- [ ] **Step 2: Build after replacing the view**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: build succeeds through settings window creation. If `SettingsView()` initialization errors remain, confirm `AppDelegate.showSettings()` no longer passes `onDone`.

---

### Task 4: Add Theme-Aware Semantic Colors

**Files:**
- Modify: `pulse/Views/Colors.swift`

- [ ] **Step 1: Add semantic color helper methods**

Append this extension to `pulse/Views/Colors.swift`:

```swift
extension Color {
    static func pulsePrimaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.82) : .black.opacity(0.82)
    }

    static func pulseSecondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.38) : .black.opacity(0.48)
    }

    static func pulseTertiaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.28) : .black.opacity(0.34)
    }

    static func pulseQuaternaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.20) : .black.opacity(0.24)
    }

    static func pulseDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.08)
    }

    static func pulseSubtleBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.12)
    }

    static func pulseFieldBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.05)
    }

    static func pulseTrackBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.10)
    }
}
```

- [ ] **Step 2: Build after adding helpers**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: build succeeds because helpers are not used yet.

---

### Task 5: Apply Semantic Colors to Existing Views

**Files:**
- Modify: `pulse/Views/PopoverView.swift`
- Modify: `pulse/Views/MetricRowView.swift`
- Modify: `pulse/Views/ProcessListView.swift`
- Modify: `pulse/Views/ProcessRowView.swift`

- [ ] **Step 1: Update PopoverView divider**

In `pulse/Views/PopoverView.swift`, add:

```swift
@Environment(\.colorScheme) private var colorScheme
```

inside `struct PopoverView`, below the existing `@AppStorage` line.

Replace:

```swift
Divider()
    .background(Color.white.opacity(0.08))
```

with:

```swift
Divider()
    .background(Color.pulseDivider(colorScheme))
```

- [ ] **Step 2: Update MetricRowView text and track colors**

In `pulse/Views/MetricRowView.swift`, add:

```swift
@Environment(\.colorScheme) private var colorScheme
```

inside `struct MetricRowView`, before the `let` properties.

Replace hard-coded colors:

```swift
.foregroundColor(.white.opacity(0.35))
```

with:

```swift
.foregroundColor(Color.pulseSecondaryText(colorScheme))
```

Replace:

```swift
.fill(Color.white.opacity(0.08))
```

with:

```swift
.fill(Color.pulseTrackBackground(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.28))
```

with:

```swift
.foregroundColor(Color.pulseTertiaryText(colorScheme))
```

- [ ] **Step 3: Update ProcessListView field, headers, dividers, and footer**

In `pulse/Views/ProcessListView.swift`, add:

```swift
@Environment(\.colorScheme) private var colorScheme
```

inside `struct ProcessListView`, before `@EnvironmentObject var monitor`.

Replace:

```swift
.foregroundColor(.white.opacity(0.8))
.background(Color.white.opacity(0.07))
.overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
```

with:

```swift
.foregroundColor(Color.pulsePrimaryText(colorScheme))
.background(Color.pulseFieldBackground(colorScheme))
.overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.pulseSubtleBorder(colorScheme), lineWidth: 1))
```

Replace:

```swift
Divider().background(Color.white.opacity(0.06))
```

with:

```swift
Divider().background(Color.pulseDivider(colorScheme))
```

Replace:

```swift
Divider().background(Color.white.opacity(0.04))
```

with:

```swift
Divider().background(Color.pulseDivider(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.20))
```

with:

```swift
.foregroundColor(Color.pulseQuaternaryText(colorScheme))
```

In `sortHeader`, replace:

```swift
.foregroundColor(.white.opacity(sortByColumn == column ? 0.6 : 0.25))
```

with:

```swift
.foregroundColor(sortByColumn == column ? Color.pulseSecondaryText(colorScheme) : Color.pulseTertiaryText(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.5))
```

with:

```swift
.foregroundColor(Color.pulseSecondaryText(colorScheme))
```

- [ ] **Step 4: Update ProcessRowView text colors**

In `pulse/Views/ProcessRowView.swift`, add:

```swift
@Environment(\.colorScheme) private var colorScheme
```

inside `struct ProcessRowView`, before `let process`.

In `cpuColor`, replace:

```swift
case ..<5: return .white.opacity(0.6)
```

with:

```swift
case ..<5: return Color.pulseSecondaryText(colorScheme)
```

Replace:

```swift
.foregroundColor(.white.opacity(0.82))
```

with:

```swift
.foregroundColor(Color.pulsePrimaryText(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.30))
```

with:

```swift
.foregroundColor(Color.pulseTertiaryText(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.20))
```

with:

```swift
.foregroundColor(Color.pulseQuaternaryText(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.28))
```

with:

```swift
.foregroundColor(Color.pulseTertiaryText(colorScheme))
```

Replace:

```swift
.foregroundColor(.white.opacity(0.38))
```

with:

```swift
.foregroundColor(Color.pulseSecondaryText(colorScheme))
```

- [ ] **Step 5: Build after semantic color replacement**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: build succeeds with no unresolved `Color.pulse...` symbols.

---

### Task 6: Bump Feature Version

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Update MARKETING_VERSION**

Replace every occurrence of:

```text
MARKETING_VERSION = 1.1.1;
```

with:

```text
MARKETING_VERSION = 1.2.0;
```

Use a patch, not a blind shell edit, so only intended lines change.

- [ ] **Step 2: Verify the version value**

Run:

```bash
grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj
```

Expected output contains:

```text
MARKETING_VERSION = 1.2.0;
```

---

### Task 7: Final Verification

**Files:**
- No edits unless verification reveals issues.

- [ ] **Step 1: Run required clean build verification**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Launch the app for manual verification**

Run:

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'pulse.app' -path '*/Debug/*' | head -1)"
```

Expected: Pulse appears in the macOS menu bar and does not show a Dock icon.

- [ ] **Step 3: Manual UI checks**

Verify these behaviors:

- Right-clicking the menu bar item shows `Open` or `Close`, `Settings...`, and `Quit Pulse`.
- Selecting `Settings...` opens a titled settings window.
- The settings window has a left sidebar with `Theme` selected.
- The right pane shows `System`, `Dark`, and `Light` in a segmented picker.
- Selecting `Dark` makes the settings window and monitor panel dark.
- Selecting `Light` makes the settings window and monitor panel light, with readable text and dividers.
- Selecting `System` follows the macOS appearance.
- Closing and relaunching the app preserves the selected theme.
- Opening settings or the monitor panel does not leave a Dock icon visible.

- [ ] **Step 4: Inspect working tree**

Run:

```bash
git status --short
```

Expected modified/added files are limited to the implementation files, the spec/plan docs if still uncommitted, and `pulse.xcodeproj/project.pbxproj` for the version bump.

Do not commit unless the user explicitly requests a commit.

---

## Self-Review Notes

- Spec coverage: the plan covers the right-click `Settings...` entry, standalone two-pane settings window, Theme sidebar section, System/Dark/Light selection, persistence through `ThemeManager`, immediate AppKit appearance updates, semantic light-mode colors, no Dock icon preservation, and version bumping.
- Placeholder scan: no `TBD`, `TODO`, or deferred implementation steps remain.
- Type consistency: `ThemeManager`, `AppTheme.nsAppearance`, `SettingsView()`, `settingsWindow`, `showSettings`, and `Color.pulse...` names are defined before use.
