# AGENTS.md — pulse

Compact repo guide for future OpenCode sessions.

## Project

- macOS 14+ menu bar app in Swift 5.9+; AppKit entrypoint is `pulse/App/main.swift` -> `AppDelegate`
- Targets: `pulse`, `pulseUpdater`, `pulseTests`
- No external dependencies; use only Apple frameworks plus the system `SQLite3` library
- `LSUIElement = true` must stay enabled so the app stays Dock-less

## Build And Verify

- Build app: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
- Run tests: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
- Build release artifacts: `bash scripts/build-dmg.sh`
- `scripts/build-dmg.sh` reads `MARKETING_VERSION` from `pulse.xcodeproj/project.pbxproj` and writes `dist/Pulse-<version>.dmg` plus `dist/Pulse-<version>-updater.zip`
- Always build after changes; if you change shared logic, run the test target too

## Architecture That Matters

- `AppDelegate` owns the status item, the custom resizable `InputPanel`, the reusable settings window, the theme object, the agent-usage store, and the updater manager
- The main panel is not an `NSPopover`; it is a borderless `NSPanel` with rounded corners, outside-click dismissal, and temporary `.regular` activation while opening settings
- `PopoverView` switches tabs with `.opacity` + `.allowsHitTesting`; `selectedTab` is persisted with `@AppStorage("selectedTab")`
- Because tab content stays mounted behind `.opacity` + `.allowsHitTesting`, `onAppear` is not a reliable hook for "panel reopened" behavior; use the `pulsePanelDidOpen` notification from `AppDelegate.openPanel()` for Agent-tab refresh-on-open behavior
- `SystemMonitor` is the single source of truth for CPU, memory, GPU, and process data and refreshes every 2 seconds
- Agent Usage is optional and off by default; `All` mode merges OpenCode and Codex summaries in memory and hides session/model sections
- Agent usage refresh is intentionally event-driven, not scheduled: refresh when the panel opens onto the Agent tab, and when switching onto the Agent tab during an open session; do not refresh just because the source picker changes between `OpenCode`, `Codex`, and `All`
- `pulseUpdater` is a separate helper app bundled into `Contents/Helpers/PulseUpdater.app` for installs

## Repo-Specific Conventions

- Keep semantic colors from `pulse/Views/Colors.swift`; avoid hard-coded light/dark values
- Do not introduce `@StateObject` into views that already receive environment objects from `AppDelegate`
- `SettingsView` must stay resizable; do not hard-code an outer frame that fights the `520x280` minimum window size
- When adding Swift files, update the Xcode project too; use `add_files.rb` or edit `pulse.xcodeproj/project.pbxproj` directly
- Version bumps live in `pulse.xcodeproj/project.pbxproj` (`MARKETING_VERSION`); release workflow `workflow_dispatch` in `.github/workflows/release.yml` publishes from that value

## SQLite Database Open Pattern (DO NOT REGRESS)

All read-only SQLite opens must use the URI form with `immutable=1`:
```swift
let uri = "file://\(databaseURL.path)?immutable=1"
sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
```
- `immutable=1` tells SQLite the file is static, avoiding attempts to create/lock WAL/SHM files on read-only filesystems
- Using a plain path (`sqlite3_open_v2(path, ...)`) breaks DB opens when WAL-mode databases are present on disk
- Both `CodexUsageQuery.openReadOnlyDatabase` and all `OpenCodeUsageStore` open sites must follow this pattern
- This has regressed twice; do NOT "simplify" it back to a plain path

## High-Signal File Map

- `pulse/App/AppDelegate.swift` - status item, panel lifecycle, settings window, theme/app activation, updater wiring
- `pulse/Views/PopoverView.swift` - main tab switcher and panel sizing trigger
- `pulse/Managers/AgentUsageStore.swift` - refresh logic and derived agent-usage view data
- `pulse/Managers/OpenCodeUsageStore.swift` - OpenCode SQLite discovery and reads
- `pulse/Managers/CodexUsageQuery.swift` - Codex mixed data loading: SQLite state DB for session/detail metadata, transcript `.jsonl` files under `~/.codex` for daily token buckets
- `scripts/build-dmg.sh` - release packaging
- `pulseUpdater/` - updater helper target

## Agent Usage Data Source Facts

- OpenCode currently resolves a single `opencode.db` from a short candidate list:
  - `OPENCODE_DB_PATH`
  - `$XDG_DATA_HOME/opencode/opencode.db`
  - `~/.local/share/opencode/opencode.db`
  - `~/Library/Application Support/opencode/opencode.db`
- OpenCode should normally have one real database file plus SQLite sidecars (`-wal`, `-shm`); do not treat sidecars as separate history sources
- Codex is different: it may have multiple `state_*.sqlite` files with overlapping but non-identical thread history
- Codex can also have invalid higher-version files that exist on disk but do not contain a `threads` table; those must be ignored
- Codex session/detail metadata should be built from the union of all valid state DBs, keyed by `thread.id`, keeping the row with the newest `updated_at_ms`
- Codex token usage should remain transcript-authoritative from `~/.codex/sessions/**/*.jsonl`; DB `tokens_used` is metadata/fallback, not the primary truth for ranged usage
- All agent usage time bucketing is local-calendar based, not UTC-based: `Today`, `7 Days`, and `30 Days` should include the user's current local day boundaries for both Codex transcripts and OpenCode message timestamps
- When working with day buckets, prefer helper paths that normalize through `Calendar` day starts and day identifiers; avoid raw `86400`-second window math for anything user-facing labeled as a day
- Do not regress Codex back to selecting a single preferred `sqlite/` DB path by directory alone; freshness and completeness both matter
