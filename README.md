# Pulse

A small macOS menu bar app for monitoring CPU, Memory, and GPU, with a built-in process manager, theme switching, and optional local agent usage analysis for OpenCode.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Language](https://img.shields.io/badge/language-Swift-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

---

## Preview

<table align="center">
  <tr>
    <td valign="middle">
      <img src="docs/images/preview-overview.png" width="300" alt="Pulse — Overview tab" />
    </td>
    <td valign="middle">
      <img src="docs/images/preview-processes.png" width="300" alt="Pulse — Processes tab" />
    </td>
    <td valign="middle">
      <img src="docs/images/preview-settings.png" width="300" alt="Pulse — Settings tab" />
    </td>
  </tr>
</table>

---

## Features

- **Lightweight & focused** — no bloat, only what you need for system monitoring and process management
- **Menu bar icon** — left-click opens/closes the panel; right-click shows a context menu with Open, Settings, and Quit
- **Overview tab** — animated gradient bars for CPU, Memory, and GPU with chip name and core count
- **Processes tab** — live process list with CPU%, memory, and listening ports; search by **name, working directory, or port**; sort by name, CPU, or memory; kill any process
- **Theme switching** — choose **System**, **Dark**, or **Light** in Settings; the preference is persisted in `UserDefaults`
- **Agent Usage tab** — optional OpenCode token analysis with global, project, and session scopes; searchable selectors; `All Time`, `Today`, `7 Days`, and `30 Days` filters; model breakdown at global/project scope
- **Settings window** — reusable native macOS settings window, available from the menu or `Cmd+,`
- **Agent Usage toggle** — disabled by default in Settings; enabling it adds the `Agent` tab and expands the panel for the denser layout
- **Frosted glass panel** — `NSVisualEffectView` background with rounded corners and semantic colors for both dark and light appearance
- **Resizable panel** — drag any edge to resize; green button zooms to 1.5x width / 2x height
- **DMG distribution** — one-command build to a drag-to-install `.dmg`
- **Zero dependencies** — pure Apple APIs only (Mach, IOKit, BSD proc)

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 14.0 Sonoma or later |
| Xcode | 15 or later |

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

Output: `dist/Pulse-1.4.2.dmg`

To install: open the DMG, drag `Pulse.app` to the **Applications** shortcut inside it.

---

## Running

1. A **chip icon** appears in your menu bar
2. **Left-click** the icon to open the panel
3. **Overview tab** — CPU / Memory / GPU bars refresh every 2 seconds
4. **Processes tab** — type in the search box to filter by name, path, or port; click column headers to sort; right-click any row to kill it
5. Open **Settings** to switch between System, Dark, and Light themes, and optionally enable **Agent Usage**
6. If enabled, use the **Agent tab** to inspect OpenCode usage by time range, project, and session, or refresh the local DB snapshot manually
7. **Click anywhere outside** the panel to dismiss it
8. **Right-click** the menu bar icon for Open/Close, Settings, and Quit

The app runs as a background accessory (`LSUIElement = true`) — no Dock icon, no ⌘-Tab entry.

---

## Project Structure

```
pulse/
├── App/
│   ├── main.swift              # AppKit entry point
│   └── AppDelegate.swift       # NSStatusItem, InputPanel, context menu
├── Managers/
│   ├── AppVersionInfo.swift    # Formats app and macOS version strings for Settings
│   ├── AgentUsageSettings.swift # Persists whether Agent Usage is enabled
│   ├── OpenCodeUsageModels.swift # Agent usage scopes, summaries, ranges, model breakdown
│   ├── OpenCodeUsageStore.swift  # SQLite-backed OpenCode usage loader + DB detection
│   └── ThemeManager.swift      # AppTheme enum + persisted theme preference
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
│   ├── AgentUsageView.swift    # OpenCode usage UI
│   ├── PopoverView.swift       # Root view, tab switcher, NSVisualEffectView
│   ├── ProcessListView.swift   # Filterable, sortable process table
│   ├── ProcessRowView.swift    # Per-process row with kill context menu
│   ├── SearchableSelectorView.swift # Searchable selector used by Agent Usage
│   └── SettingsView.swift      # Native settings window with theme selector and version info
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
- **Theme-aware** — follows the selected app theme (`System`, `Dark`, or `Light`) across the panel and settings window
- **Keyboard focus** — `canBecomeKey` overridden to `true`; activation policy briefly switches to `.regular` on open then back to `.accessory` (no Dock icon)
- **Dismiss on outside click** — global `NSEvent` monitor closes the panel on any click outside it
- **Adaptive size** — expands in width when Agent Usage is enabled and expands in height while the `Agent` tab is active

---

## Settings

- Open **Settings...** from the menu bar icon's right-click menu or press `Cmd+,`
- Choose between **System**, **Dark**, and **Light** themes
- Enable or disable **Agent Usage**; it is off by default
- Theme changes are applied to both the main panel and the settings window immediately
- The selected theme and Agent Usage UI state are persisted between launches

---

## Agent Usage

- Currently supports **OpenCode** only
- Reads usage from the local OpenCode SQLite database on demand
- Auto-detects the DB path from:
  - `OPENCODE_DB_PATH`
  - `XDG_DATA_HOME/opencode/opencode.db`
  - `~/.local/share/opencode/opencode.db`
  - `~/Library/Application Support/opencode/opencode.db`
- Uses the most recently modified existing DB candidate
- Supports these scopes:
  - `All Projects`
  - one selected project
  - one selected session inside a project
- Supports these time ranges:
  - `All Time`
  - `Today`
  - `7 Days`
  - `30 Days`
- Shows token details for:
  - total
  - input
  - output
  - reasoning
  - cache read
  - cache write
- Includes a **By Model** breakdown for global and project scopes
- Does not auto-refresh in the background; load happens when the panel becomes visible or when you press **Refresh**

---

## Permissions

Killing processes owned by other users requires elevated privileges. The app will silently fail on processes it doesn't own — this is intentional and safe.

---

## License

MIT
