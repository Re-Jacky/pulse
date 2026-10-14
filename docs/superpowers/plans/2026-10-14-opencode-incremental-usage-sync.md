# Unified Agent Usage Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace three separate JSON usage caches with one Pulse-owned SQLite index and source-specific incremental synchronization for OpenCode, Codex, and Claude Code.

**Architecture:** Add a shared, versioned SQLite store for source cursors and per-session/file usage contributions. Keep source collectors independent: OpenCode uses DB/WAL mtimes and session/message watermarks; Claude resumes JSONL at complete-line byte offsets; Codex skips unchanged files and replays changed files to preserve cumulative token-count semantics, replacing each changed file's aggregate transactionally. Source reads/parsing remain concurrent; cache writes are brief transactions.

**Tech Stack:** Swift 5.9+, Foundation, system SQLite3, XCTest, Xcode project `pulse.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-10-14-opencode-incremental-usage-sync-design.md`

## Global Constraints

- Keep OpenCode reads read-only and in URI form; use `immutable=1` normally and `mode=ro` when the WAL is newer than the main DB so committed WAL pages are visible. Never modify an agent's source data.
- Support OpenCode v1/v2, Codex's union of valid state DB metadata, and Claude's recursive transcript discovery.
- Keep Codex token usage transcript-authoritative; preserve current snapshot and daily-bucket semantics for all sources.
- Store derived usage and sync metadata only; never store transcript lines or raw source JSON. Claude may retain only the displayed title metadata needed by the existing usage snapshot, not the separate prompt field.
- Keep OpenCode, Codex, and Claude collection independent/concurrent; serialize only cache database writes.
- Use system SQLite3; no external dependencies.
- On failed source processing, do not advance that source's cursor; leave the work retryable.

## Review Focus

- WAL-only OpenCode commits: verify a newer WAL triggers watermark evaluation without duplicating unchanged session totals.
- Changed OpenCode message with stable session timestamp: verify the message watermark advances and that session buckets are replaced.
- Claude incomplete trailing JSONL line: verify the cursor stops at the previous newline and parses the completed line after append.
- Claude rewritten/truncated transcript: verify the old file contribution is replaced, not appended twice.
- Codex cumulative token snapshots and repeated events: verify changed-file replay preserves deltas and replacing that file's aggregate does not double-count.
- Shared-cache concurrency and failed transactions: verify source loads can overlap while writes serialize and cursors advance only with committed data.

---

### Task 1: Add the shared Pulse SQLite index store

**Files:**
- Create: `pulse/Managers/AgentUsageIndexStore.swift`
- Modify: `pulse.xcodeproj/project.pbxproj` (register the new Swift source using the repository's file-add convention)
- Create: `pulseTests/AgentUsageIndexStoreTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj` (register the new test source if required by the project)

**Interfaces:**
- `AgentUsageIndexStore.init(databaseURL: URL)` opens/initializes the versioned Pulse-owned SQLite database.
- The store exposes source-namespaced read, atomic upsert/replace, prune, and cursor operations for serialized derived-usage records; callers provide source key, entry key, metadata, and derived payload (never raw transcript data).
- Production cache URL is under `~/Library/Application Support/Pulse`; tests inject a unique temporary SQLite URL.

- [x] **Step 1: Write failing store lifecycle/concurrency tests**

Cover empty initialization, persistence across reopen, namespaced records not colliding, atomic entry replacement/removal with cursor updates, incompatible schema-version reset, corrupt-cache recovery, and concurrent writes through independent SQLite connections.

- [x] **Step 2: Run focused tests and verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageIndexStoreTests`

Expected: test target fails because the shared store does not exist.

- [x] **Step 3: Implement the shared schema and transactional API**

Use source/entry namespacing, parameterized SQL, SQLite transactions, and a busy timeout. Parse transcripts and source messages outside write transactions; transactions should only replace the affected derived entry/cursor and prune stale keys. Update the Xcode project for the new manager and test files.

- [x] **Step 4: Run the store tests and verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageIndexStoreTests`

Expected: all store lifecycle, isolation, transaction, and concurrency tests pass.

### Task 2: Move OpenCode to DB/WAL and session-watermark sync

**Files:**
- Modify: `pulse/Managers/OpenCodeUsageStore.swift`
- Modify: `pulse/Managers/OpenCodeDailyBucket.swift` only if required by the derived cache representation
- Test: `pulseTests/OpenCodeUsageStoreTests.swift`

**Interfaces:**
- `OpenCodeUsageQuery.loadUsage(databaseURL:indexDatabaseURL:)` uses `AgentUsageIndexStore` and returns the existing `OpenCodeUsageLoadResult`.
- Private v1/v2 queries return session metadata with watermark `max(session.time_updated, max(message.time_updated))` and load assistant payloads only for changed session IDs.

- [x] **Step 1: Add failing OpenCode sync tests**

Test unchanged DB/WAL fast path, WAL-only mtime change, stable session timestamp with newer message watermark, v1/v2 query behavior, replaced rather than accumulated buckets, and removed source sessions.

- [x] **Step 2: Run focused OpenCode tests and verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeUsageQueryTests`

Expected: new index/watermark tests fail before migration.

- [x] **Step 3: Implement OpenCode incremental synchronization**

Compare nanosecond mtimes for the main DB and `databaseURL.path + "-wal"`; on a source change query session/message watermarks, re-read changed sessions, replace their daily-bucket contributions transactionally, and prune deleted sessions. Advance source mtimes only when all required updates commit. Invalidate day-derived data on calendar identity changes. Use `immutable=1` normally and read-only `mode=ro` when the WAL is newer, so committed WAL pages are visible without writing to the source.

- [x] **Step 4: Run focused OpenCode tests and verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/OpenCodeUsageQueryTests`

Expected: existing v1/v2 and local-calendar tests plus new sync tests pass.

### Task 3: Move Claude Code to byte-offset transcript sync

**Files:**
- Modify: `pulse/Managers/ClaudeCodeUsageQuery.swift`
- Modify: `pulse/Managers/ClaudeCodeUsageModels.swift` only if the persisted derived entry needs a Codable representation
- Test: `pulseTests/ClaudeCodeTranscriptTests.swift`

**Interfaces:**
- `ClaudeCodeUsageQuery.loadUsage(homeDirectoryURL:fileManager:indexDatabaseURL:)` retains its single-pass snapshot/bucket result and uses one SQLite entry per transcript path.
- Persist file identity, modification time/size, last complete-line byte offset, boundary tail fingerprint, session accumulator, and file-derived buckets; do not persist line text.

- [x] **Step 1: Add failing Claude cursor tests**

Cover initial scan, unchanged-file reuse, append-only resume from the saved byte offset, incomplete final line not advancing the cursor, completed line parsed on next append, truncate/replace rebuilding only that file's contribution, file deletion pruning, and unchanged transcript not being reparsed.

- [x] **Step 2: Run focused Claude tests and verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeTranscriptTests`

Expected: offset, rewrite, and SQLite-cache assertions fail before migration.

- [x] **Step 3: Implement Claude byte-offset ingestion**

Read newly appended bytes from the last committed newline, parse complete JSONL records (including a valid final JSON object without a newline) into the per-file accumulator and daily buckets, and commit cursor plus aggregates atomically. Verify the cursor-boundary tail fingerprint; when rewrite/truncation is detected, rescan the file and replace its contribution. Keep subagent transcript discovery and usage semantics unchanged.

- [x] **Step 4: Run focused Claude tests and verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeTranscriptTests`

Expected: all existing Claude behavior tests and new cursor tests pass.

### Task 4: Move Codex transcript cache/cursors into the shared index

**Files:**
- Modify: `pulse/Managers/CodexUsageQuery.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`
- Test: `pulseTests/CodexSessionTranscriptTests.swift`

**Interfaces:**
- `CodexUsageQuery.loadDailyBuckets(homeDirectoryURL:fileManager:indexDatabaseURL:)` keeps the existing transcript-authoritative usage behavior; snapshot/session metadata continues to merge across valid state databases.
- Persist one replaceable aggregate per rollout path with file identity/size/mtime metadata; old JSON cache is no longer the persistence layer.

- [x] **Step 1: Add failing Codex index/cursor tests**

Test unchanged file reuse, changed file replay from the beginning with its prior aggregate replaced, no double-counting cumulative/repeated token snapshots, file replacement/truncation rebuilding that file's contribution, deleted-file pruning, and preserving the union of valid state DB session metadata.

- [x] **Step 2: Run focused Codex tests and verify they fail**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/CodexSessionTranscriptTests`

Expected: new shared-index persistence and cursor assertions fail before migration.

- [x] **Step 3: Implement CC Switch-style Codex changed-file replay**

Skip a transcript when persisted file metadata matches. On change, replay the file from the start to reconstruct cumulative token snapshots and parser context, then replace its cached aggregate in one transaction. If file identity changes or it truncates, the same full replay naturally rebuilds that file's contribution. Preserve subagent exclusion rules, transcript-authoritative usage, and parallel independence from OpenCode/Claude collection.

- [x] **Step 4: Run focused Codex tests and verify they pass**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/CodexSessionTranscriptTests`

Expected: existing Codex usage/session tests and new cursor/replay tests pass.

### Task 5: Remove legacy JSON cache paths and verify integration

**Files:**
- Modify: `pulse/Managers/OpenCodeUsageStore.swift`
- Modify: `pulse/Managers/CodexUsageQuery.swift`
- Modify: `pulse/Managers/ClaudeCodeUsageQuery.swift`
- Test: `pulseTests/OpenCodeUsageStoreTests.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`
- Test: `pulseTests/ClaudeCodeTranscriptTests.swift`

- [x] **Step 1: Remove obsolete JSON-cache persistence code**

Delete only the old OpenCode, Codex, and Claude JSON cache types/paths once all three sources pass through `AgentUsageIndexStore`; retain source-specific parsers and cache-entry models where still used.

- [x] **Step 2: Run all focused usage suites**

Run the OpenCode, Codex, Claude Code, and `AgentUsageIndexStoreTests` using their `-only-testing` selectors.

Expected: all focused suites pass, including calendar, invalid transcript, source deletion, and cache rebuild tests.

- [x] **Step 3: Run the full macOS test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`

Expected: all usage/index tests pass. The full suite still has three pre-existing `AgentIntegrationManagerTests` failures unrelated to usage indexing; report them by exact test name: `testOpenCodePluginDoesNotPromoteMetadataOrDeltaEventsToWorkingState`, `testOpenCodePluginMarksQuestionToolAsIdleAndResumesOnSuccess`, and `testOpenCodeStatusIsOutdatedWhenPluginRevisionIsStale`.

- [x] **Step 4: Check patch and branch state**

Run: `git diff --check` and `git status --short --branch`.

Expected: no whitespace errors; changes remain on `dev` and the Pulse-owned index does not touch source agent databases. The OpenCode WAL fallback is read-only and does not checkpoint or modify the source.
