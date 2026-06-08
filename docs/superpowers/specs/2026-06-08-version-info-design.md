## Goal

Add a small version information section to the menu bar panel and the settings window so the app exposes its current product version and host macOS version without adding a new screen or changing the existing navigation structure.

## Scope

- Show product version in the panel's `Overview` tab.
- Show the same version information in the settings window.
- Format the product version as `Pulse <version>` using runtime bundle metadata.
- Show the macOS version as `macOS <major>.<minor>`.
- Do not show build number.
- Do not add a new settings section, new tab, or interactive behavior.

## Existing Context

- `PopoverView` hosts a segmented control and swaps between `OverviewView` and `ProcessListView`.
- `OverviewView` currently contains three metric rows: CPU, memory, and GPU.
- `SettingsView` uses a two-pane layout with a sidebar on the left and theme controls on the right.
- The project version is managed through Xcode bundle metadata, with `MARKETING_VERSION` already set in `pulse.xcodeproj/project.pbxproj`.

## Proposed Design

### Shared Version Data Source

Add a small shared helper responsible for producing the display strings used by both views.

Responsibilities:

- Read `CFBundleShortVersionString` from `Bundle.main`.
- Format the app string as `Pulse <version>`.
- Read the current operating system version from `ProcessInfo.processInfo.operatingSystemVersion`.
- Format the system string as `macOS <major>.<minor>`.
- Fall back to `Pulse` if the bundle version is missing or empty.

This helper should stay minimal and focused on formatting, not state management. It does not need to be an `ObservableObject` because the values are static for the life of the process.

### Overview Panel Placement

Add a compact footer-style section at the bottom of `OverviewView`, below the existing metric rows.

Layout characteristics:

- Keep the current metric rows unchanged.
- Separate the version block from the metrics visually using spacing and, if needed, a subtle divider or secondary text treatment.
- Render two stacked lines:
  - `Pulse 1.2.0`
  - `macOS 14.5`
- Style the text as secondary/supporting information rather than primary content.

This keeps version metadata visible in the panel without pretending it is another system metric.

### Settings Window Placement

Add the same version block to the right-hand content pane of `SettingsView`, below the existing theme picker content.

Layout characteristics:

- Preserve the current two-pane settings structure.
- Keep the theme controls as the primary content.
- Place the version block near the bottom of the detail column using the existing vertical layout.
- Avoid introducing fixed outer sizes or new sections that would make resizing behavior worse.

This gives users a second persistent place to inspect the current app version without adding more navigation.

## Alternatives Considered

### 1. Add version info as a fourth metric row in `OverviewView`

Rejected because version data is metadata, not a live metric, and placing it in `MetricRowView` would blur the purpose of the overview rows.

### 2. Add a panel-wide footer visible on every tab

Rejected because the request only needs version info in the overview and settings contexts, and a panel-wide footer would consume shared space in the processes tab for no clear gain.

### 3. Add a separate settings section for app info

Rejected because it adds navigation and structure for information that fits comfortably in the existing theme detail pane.

## Error Handling

- If `CFBundleShortVersionString` is unavailable, display `Pulse` rather than placeholder text or an empty suffix.
- If the operating system version cannot be represented beyond available fields, use the `major.minor` pair exposed by `ProcessInfo`.

## Testing Strategy

Follow TDD for the shared formatter/helper.

Test cases:

- Formats a non-empty app version as `Pulse <version>`.
- Falls back to `Pulse` when the version is missing or blank.
- Formats the operating system version as `macOS <major>.<minor>`.

UI wiring can rely on the helper output rather than snapshot-style UI tests, since this project currently uses build verification as its primary safety net.

## Verification

- Run focused tests for the new formatter/helper.
- Run `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`.

## Non-Goals

- Showing build number.
- Adding update-checking behavior.
- Adding a dedicated About window.
- Displaying additional system metadata beyond the requested macOS version.
