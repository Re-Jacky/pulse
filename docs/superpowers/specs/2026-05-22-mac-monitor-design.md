# Mac Monitor — Design Spec
*Date: 2026-05-22*

## Overview

A lightweight macOS menu bar app that displays CPU, Memory, and GPU usage plus a process manager. Designed to look significantly better than Stats while covering only the essentials.

**Goals:**
- Beautiful, native-feeling UI — not an afterthought
- Zero external dependencies
- Minimal resource footprint (monitoring tool must not hog what it monitors)
- CPU, Memory, GPU metrics + process list with kill support

**Non-goals:**
- Network, disk, battery, fan, temperature monitoring
- Historical charts or data persistence
- Preferences window or extensive configuration

---

## Tech Stack

- **Language**: Swift 5.9+
- **UI**: SwiftUI + AppKit (NSStatusItem, NSPopover)
- **Minimum target**: macOS 13 Ventura
- **Build**: Xcode project, no package manager needed
- **Dependencies**: None — pure Apple APIs only

---

## Architecture

### App Structure

```
AppDelegate (NSApplicationDelegate)
  └── NSStatusItem  ← menu bar icon
        └── NSPopover
\              └── PopoverView (SwiftUI root)
                    ├── Tab: OverviewView
                    └── Tab: ProcessListView
```

### Data Layer

`SystemMonitor: ObservableObject` — single shared instance, owns all sub-monitors, drives a 2-second `Timer` to refresh all metrics.

| Monitor | API | Data |
|---|---|---|
| `CPUMonitor` | `host_processor_info` (Mach) | Overall usage % |
| `MemoryMonitor` | `host_statistics64` (Mach) | Used / total GB |
| `GPUMonitor` | IOKit `IOAccelerator` registry | Utilization % |
| `ProcessMonitor` | `proc_listallpids` + `proc_pidinfo` (BSD) | PID, name, CPU%, MEM |

**Data flow**: `Timer` fires → each monitor reads its API → updates `@Published` properties → SwiftUI views re-render automatically.

No persistence. No history. Live data only.

---

## UI Spec

### Menu Bar Icon

- SF Symbol: `cpu` (or `memorychip` — pick whichever renders crisper at 16pt)
- Template image rendering — adapts to light/dark menu bar automatically
- No text alongside the icon
- Click → toggle popover

### Popover

| Property | Value |
|---|---|
| Width | 300px |
| Height (Overview) | ~240px (auto-sizes to content) |
| Height (Processes) | ~420px |
| Background | `NSVisualEffectView`, material `.hudWindow` |
| Corner radius | 14px |
| Padding | 16px all sides |
| Font | SF Pro (system font) |

### Tab Bar

- Two tabs: **Overview** · **Processes**
- Full-width segmented control at top of popover
- Inactive: white 35% opacity, no background
- Active: white 92%, white 12% fill pill, subtle shadow

### Overview Tab — Metric Rows

Each metric (CPU, Memory, GPU) follows this layout:

```
[LABEL]  [══════════════bar══════════════]  [VALUE]
          subtext (core count, total RAM)
```

**Label**: 10px, uppercase, letter-spacing 1.2px, white 35%, fixed 36px width  
**Bar track**: flex fill, height 4px, border-radius 2px, white 8% background  
**Bar fill**: gradient, animates with `withAnimation(.easeInOut(duration: 0.4))`  
**Value**: 12px, semibold, fixed 44px width, right-aligned, colored to match bar  
**Subtext**: 10px, white 28%, left-aligned, indented to align under bar  
**Row gap**: 18px between metrics

**Accent colors:**

| Metric | Gradient | Color token |
|---|---|---|
| CPU | `#60d394 → #4ade80` | Green |
| Memory | `#60a5fa → #818cf8` | Blue → Purple |
| GPU | `#f472b6 → #e879f9` | Pink → Violet |

**Memory value format**: `X.X / Y GB` (e.g. `9.9 / 16 GB`)  
**CPU subtext**: core count + chip name (e.g. `10-core · Apple M3 Pro`)  
**GPU subtext**: core count + chip name (e.g. `16-core · Apple M3 Pro`)

### Processes Tab

**Search field**
- Full width, height 28px, corner radius 7px
- Placeholder: `Filter by name or port…`
- Background: white 7% + border white 10%
- Filters live as user types (no debounce needed — list is small)
- If input is a pure number (e.g. `3000`), filter by open port; otherwise filter by name substring (case-insensitive)

**Column header row**
- Columns: `NAME` (flex) · `CPU` (38px right) · `MEM` (44px right)
- 9px, uppercase, white 25%, tappable to toggle sort direction
- Default sort: CPU% descending

**Process rows**
- Height: 36px
- Left side: process name (12px, white 82%) stacked over PID (10px, white 30%)
  - If process has a known listening port, show it alongside PID: `PID 3201 · :3000`
- Right side: CPU% (11px, semibold, color-coded) stacked over MEM (10px, white 38%)
- Separator: white 4% between rows
- Hover: white 5% background fill, border-radius 5px

**CPU color coding:**
- `< 5%` → white 60% (neutral)
- `5–70%` → `#60d394` (green)  
- `70–90%` → `#f59e0b` (amber)
- `> 90%` → `#ef4444` (red)

**Kill process**
- Right-click context menu → single item: **Kill Process**
- Confirmation alert: `"Kill [ProcessName] (PID [n])?"` with **Cancel** and **Kill** (destructive red)
- On failure (permissions): show error alert, do not crash
- Uses `kill(pid, SIGTERM)` — no `SIGKILL` unless SIGTERM fails

**Footer hint**: `Right-click a process to kill it` — 10px, white 20%, centered below list

---

## Color & Typography Reference

| Token | Value |
|---|---|
| Popover background | `NSVisualEffectView` `.hudWindow` |
| Primary text | white 85% |
| Secondary text | white 35–40% |
| Tertiary text | white 25–28% |
| CPU accent | `#60d394` |
| Memory accent | `#60a5fa` |
| GPU accent | `#f472b6` |
| CPU high (70–90%) | `#f59e0b` |
| CPU critical (>90%) | `#ef4444` |
| Separator | white 4–6% |
| Base font | SF Pro, `-apple-system` |
| Value font size | 12px semibold |
| Label font size | 10px uppercase |
| Subtext font size | 10px |

---

## Error Handling

| Scenario | Behavior |
|---|---|
| GPU unavailable (VM, no IOKit entry) | Show `N/A` in GPU row, no crash |
| Process kill permission denied | Alert with error message, no crash |
| API call returns error | Silently keep last known value, retry on next tick |
| Process disappears between list and kill | Gracefully handle `ESRCH`, show "Process no longer exists" |

---

## File Structure (Planned)

```
pulse/
├── pulse.xcodeproj
└── pulse/
    ├── App/
    │   └── AppDelegate.swift
    ├── Monitors/
    │   ├── SystemMonitor.swift
    │   ├── CPUMonitor.swift
    │   ├── MemoryMonitor.swift
    │   ├── GPUMonitor.swift
    │   └── ProcessMonitor.swift
    ├── Views/
    │   ├── PopoverView.swift
    │   ├── OverviewView.swift
    │   ├── MetricRowView.swift
    │   ├── ProcessListView.swift
    │   └── ProcessRowView.swift
    └── Assets.xcassets
```
