# AGENTS.md — mac-monitor

Agent configuration and codebase context for AI assistants working on this project.

---

## Project Identity

- **Type**: macOS menu bar app (AppKit + SwiftUI hybrid)
- **Language**: Swift 5.9+, macOS 13+ target
- **Dependencies**: None — pure Apple frameworks only (AppKit, SwiftUI, IOKit, Foundation)
- **Entry point**: `mac-monitor/App/main.swift` → `AppDelegate`

---

## Build & Verify

```bash
# Build
xcodebuild -project mac-monitor.xcodeproj -scheme mac-monitor -configuration Debug build 2>&1 | tail -5

# Launch
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'mac-monitor.app' -path '*/Debug/*' | head -1)"
```

**Always build after any change.** A clean build is the only verification that counts.

---

## Architecture

```
AppDelegate (NSStatusItem + NSPopover)
  └── PopoverView (SwiftUI root, tab switcher)
        ├── OverviewView   (CPU / Memory / GPU bars)
        └── ProcessListView (search / sort / kill)

SystemMonitor (ObservableObject, 2s Timer)
  ├── CPUMonitor      → host_processor_info
  ├── MemoryMonitor   → host_statistics64
  ├── GPUMonitor      → IOKit IOAccelerator
  └── ProcessMonitor  → BSD proc APIs + kill(2)
```

`SystemMonitor` is the single source of truth. It's instantiated once in `AppDelegate` and injected via `.environmentObject(monitor)`. All views read from it via `@EnvironmentObject`.

---

## Key Files

| File | Purpose |
|------|---------|
| `App/AppDelegate.swift` | NSStatusItem setup, NSPopover toggle |
| `App/main.swift` | AppKit entry point |
| `Monitors/SystemMonitor.swift` | ObservableObject, refresh timer |
| `Monitors/CPUMonitor.swift` | CPU usage % + core count + chip name |
| `Monitors/MemoryMonitor.swift` | Memory used/total in GB |
| `Monitors/GPUMonitor.swift` | GPU usage % via IOKit |
| `Monitors/ProcessMonitor.swift` | Process list, port enrichment, kill |
| `Views/Colors.swift` | Color(hex:) + brand palette |
| `Views/MetricRowView.swift` | Animated gradient bar (reusable) |
| `Views/OverviewView.swift` | Three metric rows |
| `Views/PopoverView.swift` | Root view + NSVisualEffectView |
| `Views/ProcessListView.swift` | Filterable, sortable process table |
| `Views/ProcessRowView.swift` | Single process row + kill context menu |

---

## Conventions

### Naming
- Monitors are value-typed structs returned from `.read()` — e.g., `CPUMonitor().read()` returns a `CPUSample`
- `ProcessInfo2` (not `ProcessInfo`) to avoid collision with Foundation's class
- Errors use nested enums: `ProcessMonitor.KillError` conforming to `CustomStringConvertible`

### SwiftUI patterns
- No `@StateObject` in views — `SystemMonitor` flows down as `@EnvironmentObject`
- `NSHostingController` bridges AppKit → SwiftUI at the popover boundary
- `VisualEffectView` is an `NSViewRepresentable` wrapping `NSVisualEffectView`

### No-gos (hard constraints)
- **No external dependencies** — no SPM packages, no CocoaPods
- **No `as any`, `@ts-ignore` equivalents** — no `as! AnyObject` force casts to suppress errors
- **No disk/network/battery monitoring** — scope is CPU + Memory + GPU + Processes only
- **No Dock icon / menu bar app switcher** — `LSUIElement = true` must stay

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

### Change popover size

In `PopoverView.swift`, adjust `.frame(width:height:)`.

### Change the menu bar icon

In `AppDelegate.applicationDidFinishLaunching`:
```swift
button.image = NSImage(systemSymbolName: "cpu", ...)
```
Any SF Symbol name works. Keep `isTemplate = true` so macOS handles dark/light tinting.

---

## What Was Intentionally Left Out

- No history / charts over time
- No persistence (UserDefaults, CoreData)
- No network or disk I/O monitoring
- No Dock presence
- No sparkle / auto-update
