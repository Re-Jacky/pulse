# Distribution, Theme Switching & Quit Menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DMG build script, live theme switching (System/Dark/Light) via Preferences window, and a right-click context menu with Quit on the menu bar icon.

**Architecture:** `ThemeManager` (ObservableObject + UserDefaults) is owned by `AppDelegate` and injected into both the popover and settings window. `AppDelegate` handles dual left/right-click routing on the status button. A shell script wraps `hdiutil` for DMG packaging.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Combine, UserDefaults, hdiutil (shell)

---

## File Map

| Action | File |
|--------|------|
| Create | `mac-monitor/Managers/ThemeManager.swift` |
| Create | `mac-monitor/Views/SettingsView.swift` |
| Modify | `mac-monitor/App/AppDelegate.swift` |
| Create | `scripts/build-dmg.sh` |

---

### Task 1: ThemeManager

**Files:**
- Create: `mac-monitor/Managers/ThemeManager.swift`

- [ ] **Step 1: Create ThemeManager.swift**

```swift
import AppKit
import Combine

enum AppTheme: String, CaseIterable {
    case system = "system"
    case dark   = "dark"
    case light  = "light"

    var label: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        }
    }
}

final class ThemeManager: ObservableObject {
    static let userDefaultsKey = "appTheme"

    @Published var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
        currentTheme = AppTheme(rawValue: saved) ?? .dark
    }
}
```

- [ ] **Step 2: Build to verify no errors**

```bash
xcodebuild -project mac-monitor.xcodeproj -scheme mac-monitor -configuration Debug build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add mac-monitor/Managers/ThemeManager.swift
git commit -m "feat: add ThemeManager with UserDefaults persistence"
```

---

### Task 2: SettingsView

**Files:**
- Create: `mac-monitor/Views/SettingsView.swift`

- [ ] **Step 1: Create SettingsView.swift**

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Appearance")
                .font(.headline)

            Picker("Theme", selection: $themeManager.currentTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 260, height: 110)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project mac-monitor.xcodeproj -scheme mac-monitor -configuration Debug build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add mac-monitor/Views/SettingsView.swift
git commit -m "feat: add SettingsView with theme picker"
```

---

### Task 3: Wire AppDelegate — theme + settings window + context menu

**Files:**
- Modify: `mac-monitor/App/AppDelegate.swift`

- [ ] **Step 1: Replace AppDelegate.swift entirely**

```swift
import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        return p
    }()
    private let monitor = SystemMonitor()
    private let themeManager = ThemeManager()
    private var settingsWindow: NSWindow?
    private var themeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Popover
        let vc = NSHostingController(
            rootView: PopoverView()
                .environmentObject(monitor)
                .environmentObject(themeManager)
        )
        popover.contentViewController = vc

        // Apply initial theme
        applyTheme(themeManager.currentTheme)

        // React to theme changes
        themeCancellable = themeManager.$currentTheme.sink { [weak self] theme in
            self?.applyTheme(theme)
        }

        // Status bar button
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
            button.image?.isTemplate = true
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: - Theme

    private func applyTheme(_ theme: AppTheme) {
        let appearance = theme.nsAppearance
        popover.contentViewController?.view.appearance = appearance
        settingsWindow?.appearance = appearance
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()
        let openTitle = popover.isShown ? "Close" : "Open"
        menu.addItem(NSMenuItem(title: openTitle, action: #selector(togglePopover), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit mac-monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore left-click action behavior
    }

    // MARK: - Preferences window

    @objc private func openPreferences() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preferences"
        win.isReleasedWhenClosed = false
        win.center()
        win.appearance = themeManager.currentTheme.nsAppearance
        win.contentViewController = NSHostingController(
            rootView: SettingsView(onDone: { [weak win] in win?.close() })
                .environmentObject(themeManager)
        )
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project mac-monitor.xcodeproj -scheme mac-monitor -configuration Debug build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add mac-monitor/App/AppDelegate.swift
git commit -m "feat: wire theme manager, right-click context menu, preferences window"
```

---

### Task 4: DMG build script

**Files:**
- Create: `scripts/build-dmg.sh`

- [ ] **Step 1: Create scripts/build-dmg.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="mac-monitor"
VERSION="1.0.0"
SCHEME="mac-monitor"
PROJECT="mac-monitor.xcodeproj"
CONFIG="Release"
DIST_DIR="dist"
STAGING_DIR="/tmp/${APP_NAME}-dmg-staging"

echo "==> Building ${APP_NAME} (${CONFIG})..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  build

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "${APP_NAME}.app" \
  -path "*/${CONFIG}/*" \
  | head -1)

if [ -z "${APP_PATH}" ]; then
  echo "ERROR: Could not find built .app" >&2
  exit 1
fi

echo "==> Found app at: ${APP_PATH}"

mkdir -p "${DIST_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_TMP="/tmp/${APP_NAME}-tmp.dmg"
DMG_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_TMP}"

mv "${DMG_TMP}" "${DMG_OUT}"
rm -rf "${STAGING_DIR}"

echo "==> Done: ${DMG_OUT}"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/build-dmg.sh
```

- [ ] **Step 3: Test the script**

```bash
bash scripts/build-dmg.sh
```

Expected: `==> Done: dist/mac-monitor-1.0.0.dmg`

- [ ] **Step 4: Commit**

```bash
git add scripts/build-dmg.sh
git commit -m "feat: add hdiutil-based DMG build script"
```

---

## Self-Review

- **ThemeManager** ✓ — covers all three themes, UserDefaults persistence, `nsAppearance` computed property
- **SettingsView** ✓ — segmented picker bound to ThemeManager, Done button closes window
- **AppDelegate** ✓ — dual left/right click, Combine observer for live theme application, preferences window singleton pattern, context menu clears `statusItem.menu` after show to restore left-click
- **DMG script** ✓ — Release build → staging folder → hdiutil compress → dist/
- **Spec coverage** ✓ — all three features from spec implemented
- **No placeholders** ✓ — all steps have complete code
