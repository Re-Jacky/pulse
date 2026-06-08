# AGENTS.md — pulse

Agent configuration and codebase context for AI assistants working on this project.

---

## Project Identity

- **Type**: macOS menu bar app (AppKit + SwiftUI hybrid)
- **Language**: Swift 5.9+, macOS 14.0+ target (Sonoma; `MACOSX_DEPLOYMENT_TARGET = 14.0` in pbxproj)
- **Dependencies**: None — pure Apple frameworks only (AppKit, SwiftUI, IOKit, Foundation)
- **Entry point**: `pulse/App/main.swift` → `AppDelegate`

---

## Build & Verify

```bash
# Build
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5

# Launch
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'pulse.app' -path '*/Debug/*' | head -1)"

# Build DMG (Release)
bash scripts/build-dmg.sh
```

**Always build after any change.** A clean build is the only verification that counts.

---

## Architecture

```
AppDelegate (NSStatusItem + InputPanel)
  └── PopoverView (SwiftUI root, tab switcher)
        ├── OverviewView    (CPU / Memory / GPU bars)
        └── ProcessListView (search / sort / kill)

SystemMonitor (ObservableObject, 2s Timer)
  ├── CPUMonitor      → host_processor_info
  ├── MemoryMonitor   → host_statistics64
  ├── GPUMonitor      → IOKit IOAccelerator
  └── ProcessMonitor  → BSD proc APIs + kill(2)
```

`SystemMonitor` is the single source of truth. Instantiated once in `AppDelegate`, injected via `.environmentObject(monitor)`. All views read it via `@EnvironmentObject`.

`ThemeManager` is a second `ObservableObject` instantiated in `AppDelegate` and injected the same way — views receive it via `@EnvironmentObject var themeManager: ThemeManager`. It persists the selected `AppTheme` (.system/.dark/.light) to `UserDefaults` under key `"appTheme"`.

Settings are managed separately from the main panel: `AppDelegate` owns a reusable `NSWindow` for `SettingsView`. The app temporarily uses `.regular` activation while that window is open so standard window behavior works (`Cmd+W`, focus, resize), then returns to `.accessory` when both the settings window and main panel are closed.

---

## Key Files

| File | Purpose |
|------|---------|
| `App/AppDelegate.swift` | NSStatusItem, InputPanel lifecycle, context menu |
| `App/main.swift` | AppKit entry point |
| `Monitors/SystemMonitor.swift` | ObservableObject, refresh timer |
| `Monitors/CPUMonitor.swift` | CPU usage % + core count + chip name |
| `Monitors/MemoryMonitor.swift` | Memory used/total in GB |
| `Monitors/GPUMonitor.swift` | GPU usage % via IOKit |
| `Monitors/ProcessMonitor.swift` | Process list, port enrichment, kill |
| `Views/Colors.swift` | Color(hex:) + brand palette |
| `Views/MetricRowView.swift` | Animated gradient bar (reusable) |
| `Views/OverviewView.swift` | Three metric rows |
| `Views/PopoverView.swift` | Root view, tab switcher, NSVisualEffectView |
| `Views/ProcessListView.swift` | Filterable, sortable process table |
| `Views/ProcessRowView.swift` | Single process row + kill context menu |
| `Views/SettingsView.swift` | Two-pane settings window content (left sidebar, right detail pane) |
| `Managers/ThemeManager.swift` | `AppTheme` enum + `ObservableObject` persisting theme choice |
| `scripts/build-dmg.sh` | hdiutil-based DMG packager |

---

## Panel Architecture (important — not a standard NSPopover)

The main window is `InputPanel`, a custom `NSPanel` subclass in `AppDelegate.swift`:

- **styleMask**: `.borderless + .resizable + .fullSizeContentView` — no title bar, no traffic lights
- **canBecomeKey / canBecomeMain**: overridden to `true` — required for SwiftUI TextField focus
- **Rounded corners**: `contentView.layer?.cornerRadius = 12` + `masksToBounds`, window is transparent/non-opaque
- **Activation**: opens with `setActivationPolicy(.regular)` → `activate` → `makeKeyAndOrderFront`, then immediately reverts to `.accessory` via `DispatchQueue.main.async` — keyboard works, no Dock icon appears
- **Zoom**: overrides `zoom(_:)` to scale 1.5× width / 2× height instead of going fullscreen
- **Dismiss**: global `NSEvent` monitor closes panel on outside click

## Settings Window

- Opened from the menu bar right-click context menu via `Settings...`
- Also registered in the app menu with `Cmd+,`
- Backed by a reusable `NSWindow` in `AppDelegate` — reopening should reuse and bring the same window forward
- **Resizable**: window min size is `520x280`; `SettingsView` must not hard-code a fixed outer width/height or horizontal resizing breaks
- The app must stay `.regular` while the settings window is open; reverting to `.accessory` too early causes the window to flash to front and immediately fall behind
- `Cmd+W` works through the `Window` menu wired in `AppDelegate.setupMainMenu()`; avoid adding the same `NSMenuItem` to multiple menus or AppKit will crash with `NSInternalInconsistencyException`

---

## Adding Files to the Xcode Project

When adding new Swift files, use `add_files.rb` (at repo root) or manually add entries to `project.pbxproj`. Do **not** just create the file on disk — Xcode will not compile it unless it appears in the Sources build phase.

The `project.pbxproj` currently has duplicate `PBXFileReference` entries for `ProcessRowView.swift` and `ProcessListView.swift` (two UUIDs each). Only the first UUID in the Sources phase is compiled. This is benign but do not replicate the pattern.

---

## Conventions

### Naming
- Monitors are value-typed structs returned from `.read()` — e.g., `CPUMonitor().read()` returns a `CPUSample`
- `ProcessInfo2` (not `ProcessInfo`) to avoid collision with Foundation's class
- Errors use nested enums: `ProcessMonitor.KillError` conforming to `CustomStringConvertible`

### SwiftUI patterns
- No `@StateObject` in views — `SystemMonitor` flows down as `@EnvironmentObject`
- `NSHostingController` bridges AppKit → SwiftUI at the panel boundary
- `VisualEffectView` is an `NSViewRepresentable` wrapping `NSVisualEffectView`
- Tab switching uses `.opacity` + `.allowsHitTesting` (not `if/else`) so the tab bar never shifts position
- Theme changes force SwiftUI refresh at the root via `.id(themeManager.currentTheme)` on the main panel/settings root views; without that, AppKit appearance can update but SwiftUI content may not redraw until the panel is recreated
- Use semantic colors from `Views/Colors.swift` (`appPrimaryText`, `appDivider`, etc.) instead of hard-coded `.white.opacity(...)` so light mode stays readable

### No-gos (hard constraints)
- **No external dependencies** — no SPM packages, no CocoaPods
- **No force casts** — no `as! AnyObject` to suppress errors
- **No disk/network/battery monitoring** — scope is CPU + Memory + GPU + Processes only
- **No Dock icon** — `LSUIElement = true` must stay; activation policy trick must not leave `.regular` permanently

---

## Common Tasks

### Add a new metric to the Overview

1. Add a monitor struct in `Monitors/` following the `CPUMonitor` pattern (struct with `.read() -> SomeStruct`)
2. Add `@Published` props to `SystemMonitor` and wire in `refresh()`
3. Add a `MetricRowView(...)` call in `OverviewView`

### Change refresh interval

In `SystemMonitor.init()`:
```swift
timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { ... }
```

### Change panel default size

In `AppDelegate.makePanel()`, adjust the `contentRect`:
```swift
contentRect: NSRect(x: 0, y: 0, width: 300, height: 420)
```

### Change the menu bar icon

In `AppDelegate.applicationDidFinishLaunching`:
```swift
button.image = NSImage(systemSymbolName: "cpu", ...)
```
Any SF Symbol name works. Keep `isTemplate = true` so macOS handles dark/light tinting.

### Change rounded corner radius

In `AppDelegate.makePanel()`:
```swift
contentView.layer?.cornerRadius = 12
```

### Change settings window default size

In `AppDelegate.makeSettingsWindow()`:
```swift
contentRect: NSRect(x: 0, y: 0, width: 520, height: 280)
window.minSize = NSSize(width: 520, height: 280)
```

If resizing feels capped, check `SettingsView` for fixed outer frames before changing AppKit code.

---

## Versioning

Version is defined in `pulse.xcodeproj/project.pbxproj` (`MARKETING_VERSION`). `scripts/build-dmg.sh` reads it automatically — no manual sync needed there.

**Bump the version whenever you add a feature or fix a bug:**

```bash
# Check current version
grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj

# Bump via sed (example: 1.1.1 → 1.2.0)
sed -i '' 's/MARKETING_VERSION = .*/MARKETING_VERSION = 1.2.0;/' pulse.xcodeproj/project.pbxproj
```

| Change type | Version segment to bump |
|-------------|------------------------|
| New feature | minor (`1.1.x` → `1.2.0`) |
| Bug fix | patch (`1.1.0` → `1.1.1`) |
| Breaking change | major (`1.x.x` → `2.0.0`) |

**Rule:** Any commit with `feat:` prefix → bump minor. Any commit with `fix:` prefix → bump patch. Commit the version bump in the same PR/branch as the feature or fix.

---

## What Was Intentionally Left Out

- No history / charts over time
- No persistence beyond UI state (tab selection + search text use `@AppStorage`; no CoreData)
- No network or disk I/O monitoring
- No Dock presence
- No auto-update / Sparkle
