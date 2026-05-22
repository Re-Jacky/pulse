# AGENTS.md — pulse

Agent configuration and codebase context for AI assistants working on this project.

---

## Project Identity

- **Type**: macOS menu bar app (AppKit + SwiftUI hybrid)
- **Language**: Swift 5.9+, macOS 13+ target
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

---

## What Was Intentionally Left Out

- No history / charts over time
- No persistence (UserDefaults, CoreData)
- No network or disk I/O monitoring
- No Dock presence
- No auto-update / Sparkle
- No theme switching (always dark)
