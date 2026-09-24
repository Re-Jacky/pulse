# AGENTS.md — pulse

macOS 14+ menu bar app in Swift 5.9+ (`LSUIElement = true`, Dock-less). AppKit entrypoint is `pulse/App/main.swift` → `AppDelegate`. Targets: `pulse`, `pulseUpdater`, `pulseTests`. No external dependencies — only Apple frameworks + system `SQLite3`.

## Build & Verify

- `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
- `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
- Release packaging: `bash scripts/build-dmg.sh` — reads `MARKETING_VERSION` from project.pbxproj, writes `dist/Pulse-<version>.dmg` + `dist/Pulse-<version>-updater.zip`
- CI: `.github/workflows/release.yml` — triggers on push to `main` touching `project.pbxproj` or the workflow itself; runs on `macos-26` with Xcode 26.5

## Architecture That Matters

- `AppDelegate` owns the status item, the custom resizable `InputPanel`, the reusable settings window, the theme object, the agent-usage store, and the updater manager
- The main panel is not an `NSPopover`; it is a borderless `NSPanel` with rounded corners, outside-click dismissal, and temporary `.regular` activation while opening settings
- `PopoverView` switches tabs with `.opacity` + `.allowsHitTesting`; `selectedTab` is persisted with `@AppStorage("selectedTab")`
- Because tab content stays mounted behind `.opacity` + `.allowsHitTesting`, `onAppear` is not a reliable hook for "panel reopened" behavior; use the `pulsePanelDidOpen` notification from `AppDelegate.openPanel()` for Agent-tab refresh-on-open behavior
- `SystemMonitor` is the single source of truth for CPU, memory, GPU, and process data and refreshes every 2 seconds
- Agent Usage is optional and off by default; `All` mode merges OpenCode and Codex summaries in memory and hides session/model sections
- Agent usage refresh is intentionally event-driven, not scheduled: refresh when the panel opens onto the Agent tab, and when switching onto the Agent tab during an open session; do not refresh just because the source picker changes between `OpenCode`, `Codex`, and `All`
- `pulseUpdater` is a separate helper app bundled into `Contents/Helpers/PulseUpdater.app` for installs
- The OpenCode agent-light plugin is a local file with NO imports; it exports `{ id, server, setup }` (V2 `setup(ctx)` via `ctx.event.subscribe`, V1 `server(input)`). Local plugin files cannot resolve `@opencode/plugin`, so never add that import. V2 lifecycle events map to light kinds through `session.execution.*`, `session.inbox.*`, `session.created`, and `session.renamed`; metadata/usage/text/reasoning delta events are intentionally ignored

## AgentUsageStore Performance (DO NOT REGRESS)

- SQL queries only run in `loadRefreshResult`; **range switching is purely in-memory** — no database access
- `OpenCodeUsageQuery.loadUsage` is the refresh entry point: it derives **both** the cumulative snapshot and the daily buckets from a **single** `session_message` scan (per-message JSON extracted once into the `WITH msg AS MATERIALIZED` CTE). `loadSnapshot`/`loadDailyBuckets` are thin wrappers over it. Do not reintroduce a second full scan of the OpenCode DB — on multi-GB DBs that doubled refresh time
- `AgentUsageStore.loadRefreshResult` loads OpenCode, Codex, and Claude Code **concurrently** (`DispatchQueue.concurrentPerform` + `RefreshSourceCollector`); keep sources independent so a slow OpenCode scan does not serialize the others
- `OpenCodeUsageQuery.loadSnapshot` must keep its per-message JSON extraction in a `WITH msg AS MATERIALIZED (...)` CTE. Using inline `json_extract(m.data, '$.model...')` expressions as `GROUP BY` keys makes SQLite re-parse the message `data` blobs while sorting the group keys (measured ~4x slower on a multi-GB OpenCode DB); the materialized CTE must stay for both v1 and v2 schemas
- `derivedDataCache` keyed by `selection + refreshGeneration` — same range twice hits cache; different range recomputes everything
- Pre-computed dictionaries built once in `applyRefreshResult`/`replaceStateForTesting` and shared across all derived-data paths:
  - `openCodeBucketsByModelKey` / `codexBucketsBySession` — per-model/per-session bucket groupings
  - `ocMetadataByRawID` / `cxMetadataBySession` — metadata by session ID
  - `ocSessionsByDirectory` / `cxCSessionsByDirectory` — session IDs per directory (Codex excludes subagents)
- All iteration paths must use these pre-computed dicts, not raw `state.openCodeDailyBuckets` or `state.codexDailyBuckets` (which are only checked for `.isEmpty` / passed through to state copies)
- No linear `.first(where:)` scans on bucket arrays — all replaced with O(1) dictionary lookups
- No multi-pass `.reduce()` on the same data — all aggregations are single-pass `for` loops
- `buildTokenFlowData` uses sorted day keys + cursor index scan (O(D)) not per-bucket reduce (O(B×D))
- `latestActivityDate` for `.project` scopes uses `ocSessionsByDirectory` / `cxCSessionsByDirectory` — NOT `snapshot.sessions` scan
- `codexRequestCountFromBuckets(.project)` uses `cxCSessionsByDirectory` — NOT `state.codexSnapshot.sessions.filter`
- `buildContextRows` receives pre-computed `ocScopeSummary`/`cxScopeSummary`/`ocProjectCount`/`cxProjectCount`
- `legacyTokenFlowData` has been deleted (was O(n²) dead code)

## Repo-Specific Conventions

- Keep semantic colors from `pulse/Views/Colors.swift`; avoid hard-coded light/dark values
- Do not introduce `@StateObject` into views that already receive environment objects from `AppDelegate`
- `SettingsView` must stay resizable; do not hard-code an outer frame that fights the `520x280` minimum window size
- When adding Swift files, update the Xcode project too; use `add_files.rb` or edit `pulse.xcodeproj/project.pbxproj` directly
- Version bumps live in `pulse.xcodeproj/project.pbxproj` (`MARKETING_VERSION`); CI publishes from that value on push to `main`

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
- `pulse/Managers/OpenCodeUsageStore.swift` - OpenCode SQLite discovery and reads (supports both v1 and v2 storage schemas)
- `pulse/Managers/OpenCodeIntegrationInstaller.swift` - generates the OpenCode agent-light plugin (V1 `server` + V2 `setup` entrypoints)
- `pulse/Managers/CodexUsageQuery.swift` - Codex mixed data loading: SQLite state DB for session/detail metadata, transcript `.jsonl` files under `~/.codex` for daily token buckets
- `pulse/Managers/ClaudeCodeUsageQuery.swift` - Claude Code transcript discovery, session snapshot, daily buckets, and transcript turn loading
- `pulse/Managers/ClaudeCodeUsageModels.swift` - Claude Code session/daily-bucket models
- `pulse/Managers/SessionManagementRepository.swift` - session manager source loading (OpenCode, Codex, Claude) and transcript/resume actions
- `scripts/build-dmg.sh` - release packaging
- `pulseUpdater/` - updater helper target

## Agent Usage Data Source Facts

- OpenCode multi-model sessions use a compound ID format: `sessionID::providerID::modelID::variant` for `OpenCodeSessionRecord.id` and daily bucket dictionary keys
- `rawSessionID(from:)` helper extracts the real session ID from a compound ID (everything before `::`)
- OpenCode currently resolves a single `opencode.db` from a short candidate list:
  - `OPENCODE_DB_PATH`
  - `$XDG_DATA_HOME/opencode/opencode.db`
  - `~/.local/share/opencode/opencode.db`
  - `~/Library/Application Support/opencode/opencode.db`
- OpenCode storage is schema-versioned in place: v2 writes sessions to `session_v2` and messages to `session_message` (assistant tokens/model/content embedded as JSON in `data`, message role in the `type` column), while v1 wrote `session`/`message`/`part`. `OpenCodeUsageQuery` detects the `session_v2` table and prefers it, falling back to v1 tables for unmigrated DBs
- The OpenCode snapshot query joins only `type='assistant'` rows (`LEFT JOIN ... AND type='assistant'`); without that filter, non-assistant rows with no model fall into their own zero-token model group when `session_v2.model` omits the variant
- OpenCode should normally have one real database file plus SQLite sidecars (`-wal`, `-shm`); do not treat sidecars as separate history sources
- Codex is different: it may have multiple `state_*.sqlite` files with overlapping but non-identical thread history
- Codex can also have invalid higher-version files that exist on disk but do not contain a `threads` table; those must be ignored
- Codex session/detail metadata should be built from the union of all valid state DBs, keyed by `thread.id`, keeping the row with the newest `updated_at_ms`
- Codex token usage should remain transcript-authoritative from `~/.codex/sessions/**/*.jsonl`; DB `tokens_used` is metadata/fallback, not the primary truth for ranged usage
- All agent usage time bucketing is local-calendar based, not UTC-based: `Today`, `7 Days`, and `30 Days` should include the user's current local day boundaries for both Codex transcripts and OpenCode message timestamps
- When working with day buckets, prefer helper paths that normalize through `Calendar` day starts and day identifiers; avoid raw `86400`-second window math for anything user-facing labeled as a day
- Do not regress Codex back to selecting a single preferred `sqlite/` DB path by directory alone; freshness and completeness both matter
- Claude Code has NO database: transcripts are the only source, stored as per-line JSON under `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` (directory names are an encoded form of cwd, e.g. `/Users/zyao` → `-Users-zyao`; the query never computes encoded-cwd — it scans `~/.claude/projects` recursively for `.jsonl` files, keys in the query's candidate list, not a single preferred dir)
- Claude Code token usage comes from per-assistant-message `message.usage` dicts (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`); `requestCount` = 1 per assistant message carrying a `usage` dict (including all-zero), matching OpenCode's `SUM(role='assistant' THEN 1)`; snapshot `requestCount` is 0 by design and the store enriches it from buckets in the derived path
- `modelProvider` is the constant `"Claude"` for every Claude Code record (`ClaudeCodeUsageQuery.defaultModelProvider`); model attribution is session-level (most frequent `message.model`) and documented as a known limitation
- `ClaudeCodeUsageQuery.loadUsage` is the refresh entry point: it calls `loadCachedEntries` once and derives both the snapshot and the daily buckets from that single pass; `loadSnapshot`/`loadDailyBuckets` are thin wrappers. The size+mtime `DailyBucketCache` stores both daily buckets and the per-session accumulator, so each changed transcript is parsed exactly once per refresh and unchanged transcripts are metadata-only
- Sessions with ≥1 user OR assistant message are kept (tokens may be 0), matching the 0-coalesced OpenCode LEFT JOIN and Codex `threads` table; only phantom transcript files (no conversation) are dropped; `createdAt` = earliest timestamp across all transcript lines (session start)
- Availability: `makeAvailableSources` exposes `.claudeCode` only when `~/.claude/projects` exists (dir-exists, mirroring the OpenCode/Codex file-exists predicate); the no-source fallback is `[.openCode, .codex, .claudeCode]`
