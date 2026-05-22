# mac-monitor

A beautiful macOS menu bar app for monitoring CPU, Memory, and GPU — with a built-in process manager.

Built because existing tools like [Stats](https://github.com/exelban/stats) are functional but ugly. This one prioritizes aesthetics: frosted glass popover, color-coded animated bars, clean typography.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Language](https://img.shields.io/badge/language-Swift-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

---

## Features

- **Menu bar icon** — click the chip icon to open/close the popover
- **Overview tab** — animated gradient bars for CPU, Memory, and GPU usage with chip name and core count
- **Processes tab** — live process list with CPU%, memory, and listening ports; filter by name or port; kill any process
- **Frosted glass UI** — native `NSVisualEffectView` with `.hudWindow` material
- **Zero dependencies** — pure Apple APIs (Mach, IOKit, BSD proc)

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 13.0 Ventura or later |
| Xcode | 14 or later |

No package manager, no CocoaPods, no Swift packages required.

---

## Building

### Option 1: Xcode GUI

1. Open `mac-monitor.xcodeproj` in Xcode
2. Select the `mac-monitor` scheme and your Mac as the destination
3. Press **⌘R** to build and run

### Option 2: Command Line

```bash
# Build (Debug)
xcodebuild -project mac-monitor.xcodeproj -scheme mac-monitor -configuration Debug build

# Build and find the .app
xcodebuild -project mac-monitor.xcodeproj -scheme mac-monitor -configuration Debug build \
  | grep "BUILD SUCCEEDED"

# Launch the built app
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'mac-monitor.app' -path '*/Debug/*' | head -1)"
```

> **Note:** On first build you may need to run `sudo xcodebuild -runFirstLaunch` if Xcode tools aren't initialized.

### Option 3: Build a DMG for distribution

```bash
bash scripts/build-dmg.sh
```

This builds a Release `.app` and packages it into a drag-to-install DMG using only macOS built-in tools (`hdiutil` — no Homebrew or external dependencies required).

Output: `dist/mac-monitor-1.0.0.dmg`

To install: open the DMG, drag `mac-monitor.app` to the **Applications** folder shortcut inside it.

---

## Running

After launching:

1. A **chip icon** (⬡) appears in your menu bar
2. **Click** the icon to open the monitoring popover
3. **Overview tab** — CPU / Memory / GPU bars refresh every 2 seconds
4. **Processes tab** — type in the search box to filter by process name or port number; click **Kill** on any row to terminate it (confirmation required)
5. **Click anywhere outside** the popover to dismiss it

The app runs as a background accessory (`LSUIElement = true`) — it won't appear in the Dock or ⌘-Tab switcher.

---

## Project Structure

```
mac-monitor/
├── App/
│   ├── main.swift              # AppKit entry point
│   └── AppDelegate.swift       # NSStatusItem + NSPopover setup
├── Monitors/
│   ├── SystemMonitor.swift     # ObservableObject, 2s timer, coordinates all monitors
│   ├── CPUMonitor.swift        # Mach host_processor_info
│   ├── MemoryMonitor.swift     # host_statistics64
│   ├── GPUMonitor.swift        # IOKit IOAccelerator
│   └── ProcessMonitor.swift   # BSD proc APIs, port detection, kill
└── Views/
    ├── Colors.swift            # Color(hex:) extension + palette
    ├── MetricRowView.swift     # Animated gradient bar component
    ├── OverviewView.swift      # CPU / Memory / GPU overview
    ├── PopoverView.swift       # Root view, tab switcher, NSVisualEffectView
    ├── ProcessListView.swift   # Search, sort, kill list
    └── ProcessRowView.swift    # Per-process row with context menu
```

---

## How It Works

| Layer | API Used |
|-------|----------|
| CPU usage | `host_processor_info` (Mach) |
| Memory | `host_statistics64` (Mach) |
| GPU usage | `IOKit` — `IOAccelerator` performance statistics |
| Process list | `proc_listallpids` + `proc_pidinfo` (BSD) |
| Port detection | `proc_pidfdinfo` with `PROC_PIDFDSOCKETINFO` |
| Kill | `kill(pid, SIGTERM)` |

---

## Permissions

Killing processes owned by other users requires elevated privileges. The app will silently fail to kill processes it doesn't have permission for — this is intentional and safe.

---

## License

MIT
