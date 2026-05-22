# Pulse

A beautiful macOS menu bar app for monitoring CPU, Memory, and GPU — with a built-in process manager.

Built because existing tools like [Stats](https://github.com/exelban/stats) are functional but ugly. This one prioritizes aesthetics: dark frosted-glass panel, color-coded animated bars, clean typography.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Language](https://img.shields.io/badge/language-Swift-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

---

## Features

- **Menu bar icon** — left-click opens/closes the panel; right-click shows a context menu
- **Overview tab** — animated gradient bars for CPU, Memory, and GPU with chip name and core count
- **Processes tab** — live process list with CPU%, memory, listening ports; filter by name or port; kill any process
- **Dark UI** — always-dark frosted glass panel (`NSVisualEffectView`) with rounded corners
- **Resizable panel** — drag any edge to resize; green button zooms to 1.5× width / 2× height
- **DMG distribution** — one-command build to a drag-to-install `.dmg`
- **Zero dependencies** — pure Apple APIs only (Mach, IOKit, BSD proc)

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

1. Open `pulse.xcodeproj` in Xcode
2. Select the `pulse` scheme and your Mac as the destination
3. Press **⌘R** to build and run

### Option 2: Command Line (Debug)

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build

open "$(find ~/Library/Developer/Xcode/DerivedData -name 'Pulse.app' -path '*/Debug/*' | head -1)"
```

> **Note:** On first build you may need to run `sudo xcodebuild -runFirstLaunch` if Xcode tools aren't initialized.

### Option 3: Build a DMG for distribution

```bash
bash scripts/build-dmg.sh
```

Builds a Release `.app` and packages it into a drag-to-install DMG using only macOS built-in tools (`hdiutil` — no Homebrew required).

Output: `dist/Pulse-1.0.0.dmg`

To install: open the DMG, drag `Pulse.app` to the **Applications** shortcut inside it.

---

## Running

1. A **chip icon** appears in your menu bar
2. **Left-click** the icon to open the panel
3. **Overview tab** — CPU / Memory / GPU bars refresh every 2 seconds
4. **Processes tab** — type in the search box to filter by name or port; right-click any row to kill it
5. **Click anywhere outside** the panel to dismiss it
6. **Right-click** the menu bar icon for Open/Close and Quit

The app runs as a background accessory (`LSUIElement = true`) — no Dock icon, no ⌘-Tab entry.

---

## Project Structure

```
pulse/
├── App/
│   ├── main.swift              # AppKit entry point
│   └── AppDelegate.swift       # NSStatusItem, InputPanel, context menu
├── Managers/
│   └── ThemeManager.swift      # AppTheme enum (unused currently, kept for reference)
├── Monitors/
│   ├── SystemMonitor.swift     # ObservableObject, 2s timer, coordinates all monitors
│   ├── CPUMonitor.swift        # Mach host_processor_info
│   ├── MemoryMonitor.swift     # host_statistics64
│   ├── GPUMonitor.swift        # IOKit IOAccelerator
│   └── ProcessMonitor.swift    # BSD proc APIs, port detection, kill
├── Views/
│   ├── Colors.swift            # Color(hex:) extension + palette
│   ├── MetricRowView.swift     # Animated gradient bar component
│   ├── OverviewView.swift      # CPU / Memory / GPU overview
│   ├── PopoverView.swift       # Root view, tab switcher, NSVisualEffectView
│   ├── ProcessListView.swift   # Filterable, sortable process table
│   ├── ProcessRowView.swift    # Per-process row with kill context menu
│   └── SettingsView.swift      # Unused — kept for future theme support
└── scripts/
    └── build-dmg.sh            # hdiutil-based DMG packager
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

## Panel Behavior

The main window is an `InputPanel` (custom `NSPanel` subclass) rather than the standard `NSPopover`:

- **Resizable** — drag any edge/corner
- **Rounded corners** — 12pt radius via `CALayer`, window background is transparent
- **Always dark** — `NSAppearance(named: .darkAqua)` forced on all views
- **Keyboard focus** — `canBecomeKey` overridden to `true`; activation policy briefly switches to `.regular` on open then back to `.accessory` (no Dock icon)
- **Dismiss on outside click** — global `NSEvent` monitor closes the panel on any click outside it

---

## Permissions

Killing processes owned by other users requires elevated privileges. The app will silently fail on processes it doesn't own — this is intentional and safe.

---

## License

MIT
