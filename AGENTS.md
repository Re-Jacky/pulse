# AGENTS.md — pulse

Agent configuration and codebase context for AI assistants working on this project.

---

## Project Identity

- **Type**: macOS menu bar app (AppKit + SwiftUI hybrid)
- **Language**: Swift 5.9+, macOS 14.0+ target (Sonoma; `MACOSX_DEPLOYMENT_TARGET = 14.0` in pbxproj)
- **Dependencies**: None — pure Apple frameworks only (AppKit, SwiftUI, IOKit, Foundation)
- **Entry point**: `pulse/App/main.swift` → `AppDelegate`
- **Optional feature**: Agent Usage panel for local OpenCode and Codex token analysis

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
└── AgentUsageView (OpenCode + Codex usage, source picker, combined All summary)
      └── AgentUsageFlowChartView (token flow line chart, All mode only)
 
SystemMonitor (ObservableObject, 2s Timer)
  ├── CPUMonitor      → host_processor_info
  ├── MemoryMonitor   → host_statistics64
  ├── GPUMonitor      → IOKit IOAccelerator
  └── ProcessMonitor  → BSD proc APIs + kill(2)

AgentUsageStore (ObservableObject, manual refresh)
├── DB path auto-detection (OpenCode + Codex)
├── SQLite reads from local OpenCode session DB
├── SQLite reads from local Codex threads DB
└── Aggregates global / project / session token usage (per-source or combined via All)
```

`SystemMonitor` is the single source of truth. Instantiated once in `AppDelegate`, injected via `.environmentObject(monitor)`. All views read it via `@EnvironmentObject`.

`ThemeManager` is a second `ObservableObject` instantiated in `AppDelegate` and injected the same way — views receive it via `@EnvironmentObject var themeManager: ThemeManager`. It persists the selected `AppTheme` (.system/.dark/.light) to `UserDefaults` under key `"appTheme"`.

`AgentUsageStore` is an `ObservableObject` instantiated once in `AppDelegate` and injected as an `@EnvironmentObject`. It is refresh-on-open / refresh-on-demand only; there is no background polling. The source picker (`AgentSourcePicker`) lets users switch between **All**, **OpenCode**, and **Codex** views. **All** mode merges summaries from both sources via `AgentUsageSummary.merge()`, shows a unioned project list, and hides session selector / context / by-model sections.

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
| `Managers/AgentUsageModels.swift` | Shared types — `AgentSource`, `AgentTimeRange`, `AgentScope`, `AgentUsageSummary`, `merge()` |
| `Managers/AgentUsageStore.swift` | Enum-routed `ObservableObject` combining both sources |
| `Managers/OpenCodeUsageModels.swift` | OpenCode-specific session records, snapshot, model breakdown |
| `Managers/OpenCodeUsageStore.swift` | `OpenCodeUsageQuery` enum — SQLite queries + DB path detection |
| `Managers/CodexUsageModels.swift` | Codex-specific session records, snapshot, subagent edges, goals |
| `Managers/CodexUsageQuery.swift` | Codex SQLite queries + DB path detection (scans `state_*.sqlite`) |
| `Views/Colors.swift` | Color(hex:) + brand palette |
| `Views/MetricRowView.swift` | Animated gradient bar (reusable) |
| `Views/OverviewView.swift` | Three metric rows |
| `Views/AgentUsageView.swift` | OpenCode + Codex usage UI, filters, cards, model breakdown |
| `Views/AgentUsageFlowChartView.swift` | Token flow line chart (All mode only, excludes Today) |
| `Views/AgentSourcePicker.swift` | Three-way capsule toggle (All / OpenCode / Codex) |
| `Views/CodexSessionDetailView.swift` | Subagent edges + goals for a Codex session |
| `Views/PopoverView.swift` | Root view, tab switcher, NSVisualEffectView |
| `Views/ProcessListView.swift` | Filterable, sortable process table |
| `Views/ProcessRowView.swift` | Single process row + kill context menu |
| `Views/SearchableSelectorView.swift` | Searchable project/session picker used by Agent Usage |
| `Views/SettingsView.swift` | Two-pane settings window content (left sidebar, right detail pane) |
| `Managers/AgentUsageSettings.swift` | Persists whether Agent Usage is enabled |
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
- **Dynamic sizing**: width expands when Agent Usage is enabled, and height expands when the `Agent` tab is active

## Settings Window

- Opened from the menu bar right-click context menu via `Settings...`
- Also registered in the app menu with `Cmd+,`
- Backed by a reusable `NSWindow` in `AppDelegate` — reopening should reuse and bring the same window forward
- **Resizable**: window min size is `520x280`; `SettingsView` must not hard-code a fixed outer width/height or horizontal resizing breaks
- The app must stay `.regular` while the settings window is open; reverting to `.accessory` too early causes the window to flash to front and immediately fall behind
- `Cmd+W` works through the `Window` menu wired in `AppDelegate.setupMainMenu()`; avoid adding the same `NSMenuItem` to multiple menus or AppKit will crash with `NSInternalInconsistencyException`
- `Agent Usage` lives in Settings and defaults to off; enabling it reveals the `Agent` tab in the main panel

---

## Adding Files to the Xcode Project

When adding new Swift files, use `add_files.rb` (at repo root) or manually add entries to `project.pbxproj`. Do **not** just create the file on disk — Xcode will not compile it unless it appears in the Sources build phase.

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
- Agent Usage filter state is persisted with `@AppStorage` so the last source, project, session, and time range survive reopen

### No-gos (hard constraints)
- **No external dependencies** — no SPM packages, no CocoaPods
- **No force casts** — no `as! AnyObject` to suppress errors
- **No disk/network/battery monitoring** — scope is CPU + Memory + GPU + Processes only
- **No Dock icon** — `LSUIElement = true` must stay; activation policy trick must not leave `.regular` permanently
- **No automatic agent polling** — Agent Usage loads on panel visibility / manual refresh only

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

If Agent Usage sizing changed unexpectedly, also check the sizing helpers in `AppDelegate` and the selected tab persistence in `PopoverView`.

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

### Agent Usage data sources

- **OpenCode** usage is read from a local SQLite database
  - DB detection checks, in order:
    - `OPENCODE_DB_PATH`
    - `XDG_DATA_HOME/opencode/opencode.db`
    - `~/.local/share/opencode/opencode.db`
    - `~/Library/Application Support/opencode/opencode.db`
  - The most recently modified existing candidate is selected
- **Codex** usage is read from a local SQLite database
  - DB detection checks, in order:
    - `CODEX_DB_PATH` (must exist)
    - Scans `~/.codex/` for `state_*.sqlite` files (e.g., `state_5.sqlite`, `state_6.sqlite`)
    - Picks the file with the highest version number; ties broken by most recently modified
  - Returns `nil` if no DB is found (Codex is optional)
- **All** mode merges both sources in-memory via `AgentUsageSummary.merge()`
  - Shows unioned project list, combined token totals, hidden session selector / context / by-model
- **All** mode has a token flow line chart (`AgentUsageFlowChartView`) below the Usage card when a date range other than `Today` is selected; daily buckets for 7D/30D, adaptive ~30 buckets for All Time
- Supported UI ranges are `All Time`, `Today`, `7 Days`, and `30 Days`
- Supported scopes are global, project, and session (session not available in All mode)
- Model breakdown is shown for global and project scopes, not session scope (and not in All mode)

---

## Versioning

Version is defined in `pulse.xcodeproj/project.pbxproj` (`MARKETING_VERSION`). `scripts/build-dmg.sh` reads it automatically — no manual sync needed there.

**Bump the version whenever you add a feature or fix a bug:**

```bash
# Check current version
grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj

# Bump via sed (example: 1.5.1 → 1.6.0)
sed -i '' 's/MARKETING_VERSION = .*/MARKETING_VERSION = 1.6.0;/' pulse.xcodeproj/project.pbxproj
```

| Change type | Version segment to bump |
|-------------|------------------------|
| New feature | minor (`1.1.x` → `1.2.0`) |
| Bug fix | patch (`1.1.0` → `1.1.1`) |
| Breaking change | major (`1.x.x` → `2.0.0`) |

**Rule:** Any commit with `feat:` prefix → bump minor. Any commit with `fix:` prefix → bump patch. Commit the version bump in the same PR/branch as the feature or fix.

---

## What Was Intentionally Left Out

- No persistence beyond UI state (tab selection + search text use `@AppStorage`; no CoreData)
- No network or disk I/O monitoring
- No Dock presence
- No auto-update / Sparkle
