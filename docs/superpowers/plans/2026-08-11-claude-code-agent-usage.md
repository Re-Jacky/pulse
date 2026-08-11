# Claude Code Agent Usage Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Claude Code as a third data source in the Agent Usage tab (alongside OpenCode and Codex), sourcing session metadata and per-day token buckets from Claude Code JSONL transcripts under `~/.claude/projects`.

**Architecture:** Claude Code stores one `.jsonl` transcript per session under `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`. Every `type: "assistant"` line carries a self-contained `message.usage` object (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`), plus top-level `sessionId`/`session_id`, `cwd`, `timestamp`, and `message.model`. We mirror the existing Codex transcript pipeline: `ClaudeCodeUsageQuery` scans transcripts, accumulates per-session-per-day buckets (with a size+mtime cache), and builds a session snapshot. The enum-routed `AgentUsageStore` gains a `.claudeCode` branch threaded through state, refresh, availability, and every `.all`-mode merge.

**Tech Stack:** Swift 5.9+, macOS 14.0+, AppKit + SwiftUI, Foundation `JSONSerialization`, no external dependencies, no SQLite.

---

## Global Constraints

- No new dependencies. Only Apple frameworks.
- Follow the `AgentUsageStore` performance rules in `AGENTS.md` — pre-computed dictionaries only, no linear scans of raw bucket arrays, single-pass aggregation, no multi-pass reduce.
- All time bucketing is local-calendar based via `agentUsageDayIdentifier(for:)` / `agentUsageDayInterval(for:)` (never raw 86400 math).
- Reuse the size+mtime transcript cache pattern (`CodexDailyBucketCache`) — do not re-parse unchanged transcripts.
- Claude Code transcripts are the single source of truth for both metadata and tokens; no DB lookup.
- The `.all` source hides session/model detail sections and merges per-source summaries — this must extend to a third source.
- Keep semantic colors from `pulse/Views/Colors.swift`; no new hard-coded light/dark values.
- Every new Swift file must be added to `pulse.xcodeproj/project.pbxproj` (via `scripts/add_files.rb`).
- Tests follow the existing fixture pattern in `pulseTests/CodexSessionTranscriptTests.swift` (temp home dir, `defer { try? FileManager.default.removeItem(at: root) }`).
- TDD: no production code without a failing test first.

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `pulse/Managers/ClaudeCodeUsageModels.swift` | **Create** | `ClaudeCodeSessionRecord`, `ClaudeCodeDailyBucket`, `ClaudeCodeUsageSnapshot`, project/session/model-option types |
| `pulse/Managers/ClaudeCodeUsageQuery.swift` | **Create** | Transcript discovery, snapshot building, daily bucket accumulation + cache |
| `pulse/Managers/AgentUsageModels.swift` | **Modify** | Add `.claudeCode` to `AgentSource` + `selectableCases` + `displayName`, data source description |
| `pulse/Managers/AgentUsageRepository.swift` | **Modify** | Protocol + impl: `claudeCodeProjectsURL`, `loadClaudeCodeSnapshot`, `loadClaudeCodeDailyBuckets` |
| `pulse/Managers/AgentUsageViewData.swift` | **Modify** | `AgentUsageLoadedState` gains claude fields + `.empty` |
| `pulse/Managers/AgentUsageStore.swift` | **Modify** | State plumbing, `LoadError`, availability, derived data + `.all` merges |
| `pulse/Views/AgentUsageView.swift` | **Modify** | Data source description + `databasePath` for claude |
| `pulseTests/ClaudeCodeUsageModelsTests.swift` | **Create** | In-memory snapshot summary/breakdown tests |
| `pulseTests/ClaudeCodeTranscriptTests.swift` | **Create** | Transcript parsing: snapshot + daily buckets + fallbacks |
| `pulseTests/AgentUsageStoreTests.swift` | **Modify** | Extend both repository stubs; claude source + `.all` merge tests |

`AgentUsageDerivedViewData` is NOT extended (no claude detail view; claude session scope renders via `buildContextRows`). `AgentUsageViewDataTests.swift` does not construct `AgentUsageLoadedState`/`AgentUsageDerivedViewData` directly, so no changes there.

---

### Task 1: Claude Code models

**Files:**
- Create: `pulse/Managers/ClaudeCodeUsageModels.swift`
- Test: `pulseTests/ClaudeCodeUsageModelsTests.swift`

**Interfaces (consumed by every later task — lock these names):**
- `ClaudeCodeSessionRecord(id:title:cwd:model:modelProvider:tokensUsed:inputTokens:outputTokens:cacheReadTokens:cacheWriteTokens:createdAt:updatedAt:)`
- `ClaudeCodeDailyBucket(sessionID:day:inputTokens:outputTokens:cacheReadTokens:cacheWriteTokens:totalTokens:requestCount:latestActivityAt:)` with `static func zero(sessionID:day:)` and `func merging(_:)`
- `ClaudeCodeUsageSnapshot(sessions:)` with `filtered(to:)`, `projectOptions`, `sessionOptions(for:)`, `summary(for:)`, `modelBreakdown(for:)`, `providerBreakdown(for:)`, `static func makeSummary(from:)`. No subagent filtering — every session is a top-level session.

- [ ] **Step 1: Write the failing model test**

Create `pulseTests/ClaudeCodeUsageModelsTests.swift`:

```swift
import XCTest
@testable import Pulse

final class ClaudeCodeUsageModelsTests: XCTestCase {
    private func makeSession(id: String, cwd: String, model: String, tokens: Int, updatedAt: TimeInterval) -> ClaudeCodeSessionRecord {
        ClaudeCodeSessionRecord(
            id: id,
            title: "Session \(id)",
            cwd: cwd,
            model: model,
            modelProvider: "Claude",
            tokensUsed: tokens,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    func testSnapshotSummarizesAllProjects() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "s1", cwd: "/tmp/a", model: "sonnet", tokens: 100, updatedAt: 2_000),
            makeSession(id: "s2", cwd: "/tmp/b", model: "opus", tokens: 50, updatedAt: 3_000)
        ])
        let summary = snapshot.summary(for: .allProjects)
        XCTAssertEqual(summary.totalTokens, 150)
        XCTAssertEqual(summary.sessionsCount, 2)
        XCTAssertEqual(summary.lastUpdated, Date(timeIntervalSince1970: 3_000))
    }

    func testSnapshotSortsSessionsNewestFirst() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "old", cwd: "/tmp/a", model: "sonnet", tokens: 1, updatedAt: 2_000),
            makeSession(id: "new", cwd: "/tmp/a", model: "sonnet", tokens: 2, updatedAt: 4_000)
        ])
        XCTAssertEqual(snapshot.sessions.map(\.id), ["new", "old"])
    }

    func testProjectOptionsGroupByDirectorySortedByTokens() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "s1", cwd: "/tmp/a", model: "sonnet", tokens: 100, updatedAt: 2_000),
            makeSession(id: "s2", cwd: "/tmp/b", model: "sonnet", tokens: 50, updatedAt: 3_000)
        ])
        XCTAssertEqual(snapshot.projectOptions.map(\.shortName), ["a", "b"])
        XCTAssertEqual(snapshot.projectOptions.map(\.summary.totalTokens), [100, 50])
    }

    func testModelAndProviderBreakdown() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "s1", cwd: "/tmp/a", model: "sonnet", tokens: 100, updatedAt: 2_000),
            makeSession(id: "s2", cwd: "/tmp/b", model: "opus", tokens: 50, updatedAt: 3_000)
        ])
        XCTAssertEqual(snapshot.modelBreakdown(for: .allProjects).map(\.model), ["sonnet", "opus"])
        XCTAssertEqual(snapshot.providerBreakdown(for: .allProjects).map(\.provider), ["Claude"])
    }

    func testDailyBucketMergingSumsAndTakesMaxActivity() {
        let bucketA = ClaudeCodeDailyBucket.zero(sessionID: "s1", day: 100)
        let bucketB = ClaudeCodeDailyBucket(
            sessionID: "s1", day: 100,
            inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 1,
            totalTokens: 16, requestCount: 1,
            latestActivityAt: Date(timeIntervalSince1970: 5_000)
        )
        let merged = bucketA.merging(bucketB)
        XCTAssertEqual(merged.inputTokens, 10)
        XCTAssertEqual(merged.totalTokens, 16)
        XCTAssertEqual(merged.requestCount, 1)
        XCTAssertEqual(merged.latestActivityAt, Date(timeIntervalSince1970: 5_000))
    }
}
```

- [ ] **Step 2: Register the new files in the Xcode project** (needed before any test run — `scripts/add_files.rb` does not exist; edit `pulse.xcodeproj/project.pbxproj` directly)

Create the empty files first (`touch`), then in `pulse.xcodeproj/project.pbxproj` add these four files using the repo's deterministic hex-id scheme (`1000000000000000000000E0`–`E7` are unused):

1. `PBXBuildFile` section (near line 23):
   `1000000000000000000000E0 /* ClaudeCodeUsageModels.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1000000000000000000000E1 /* ClaudeCodeUsageModels.swift */; };`
   `1000000000000000000000E2 /* ClaudeCodeUsageQuery.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1000000000000000000000E3 /* ClaudeCodeUsageQuery.swift */; };`
   `1000000000000000000000E4 /* ClaudeCodeUsageModelsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1000000000000000000000E5 /* ClaudeCodeUsageModelsTests.swift */; };`
   `1000000000000000000000E6 /* ClaudeCodeTranscriptTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1000000000000000000000E7 /* ClaudeCodeTranscriptTests.swift */; };`
2. `PBXFileReference` section (near line 139):
   `1000000000000000000000E1 /* ClaudeCodeUsageModels.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Managers/ClaudeCodeUsageModels.swift; sourceTree = "<group>"; };`
   `1000000000000000000000E3 /* ClaudeCodeUsageQuery.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = Managers/ClaudeCodeUsageQuery.swift; sourceTree = "<group>"; };`
   `1000000000000000000000E5 /* ClaudeCodeUsageModelsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ClaudeCodeUsageModelsTests.swift; sourceTree = "<group>"; };`
   `1000000000000000000000E7 /* ClaudeCodeTranscriptTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ClaudeCodeTranscriptTests.swift; sourceTree = "<group>"; };`
3. `PBXGroup` membership: add `1000000000000000000000E1` and `1000000000000000000000E3` next to `CodexUsageQuery.swift` (near line 305, the Managers group); add `1000000000000000000000E5` and `1000000000000000000000E7` to the pulseTests group.
4. `PBXSourcesBuildPhase`: in the pulse target's Sources phase (near line 600) add `1000000000000000000000E0 /* ClaudeCodeUsageModels.swift in Sources */,` and `1000000000000000000000E2 /* ClaudeCodeUsageQuery.swift in Sources */,`; in the pulseTests target's Sources phase add `1000000000000000000000E4` and `1000000000000000000000E6`.

Verify with `plutil -lint pulse.xcodeproj/project.pbxproj` → OK.

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeUsageModelsTests`
Expected: FAIL — `cannot find type 'ClaudeCodeSessionRecord' in scope`.

- [ ] **Step 4: Create `pulse/Managers/ClaudeCodeUsageModels.swift`**

```swift
import Foundation

struct ClaudeCodeSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let modelProvider: String
    let tokensUsed: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let createdAt: Date
    let updatedAt: Date

    var shortProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct ClaudeCodeDailyBucket: Codable, Equatable {
    let sessionID: String
    let day: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let latestActivityAt: Date?

    static func zero(sessionID: String, day: Int) -> ClaudeCodeDailyBucket {
        ClaudeCodeDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 0,
            requestCount: 0,
            latestActivityAt: nil
        )
    }

    func merging(_ other: ClaudeCodeDailyBucket) -> ClaudeCodeDailyBucket {
        let mergedLatestActivityAt: Date?
        switch (latestActivityAt, other.latestActivityAt) {
        case let (lhs?, rhs?): mergedLatestActivityAt = max(lhs, rhs)
        case let (lhs?, nil): mergedLatestActivityAt = lhs
        case let (nil, rhs?): mergedLatestActivityAt = rhs
        case (nil, nil): mergedLatestActivityAt = nil
        }

        return ClaudeCodeDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
            totalTokens: totalTokens + other.totalTokens,
            requestCount: requestCount + other.requestCount,
            latestActivityAt: mergedLatestActivityAt
        )
    }
}

struct ClaudeCodeProjectOption: Identifiable, Equatable {
    let id: String
    let directory: String
    let shortName: String
    let summary: AgentUsageSummary
}

struct ClaudeCodeSessionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let modelDisplayName: String
    let summary: AgentUsageSummary
    let updatedAt: Date
}

struct ClaudeCodeModelBreakdown: Identifiable, Equatable {
    var id: String { "\(modelProvider)/\(model)" }
    let modelProvider: String
    let model: String
    let summary: AgentUsageSummary
}

struct ClaudeCodeUsageSnapshot: Equatable {
    let sessions: [ClaudeCodeSessionRecord]

    init(sessions: [ClaudeCodeSessionRecord]) {
        self.sessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func filtered(to range: AgentTimeRange, now: Date = Date()) -> ClaudeCodeUsageSnapshot {
        ClaudeCodeUsageSnapshot(
            sessions: sessions.filter { range.contains($0.updatedAt, now: now) }
        )
    }

    var projectOptions: [ClaudeCodeProjectOption] {
        Dictionary(grouping: sessions, by: \.cwd)
            .map { directory, sessions in
                ClaudeCodeProjectOption(
                    id: directory,
                    directory: directory,
                    shortName: URL(fileURLWithPath: directory).lastPathComponent,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.shortName.localizedCaseInsensitiveCompare(rhs.shortName) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func sessionOptions(for directory: String) -> [ClaudeCodeSessionOption] {
        sessions
            .filter { $0.cwd == directory }
            .map { session in
                ClaudeCodeSessionOption(
                    id: session.id,
                    title: session.title,
                    directory: session.cwd,
                    modelDisplayName: "\(session.modelProvider) / \(session.model)",
                    summary: Self.makeSummary(from: [session]),
                    updatedAt: session.updatedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func summary(for scope: AgentScope) -> AgentUsageSummary {
        switch scope {
        case .allProjects:
            return Self.makeSummary(from: sessions)
        case .project(let directory):
            return Self.makeSummary(from: sessions.filter { $0.cwd == directory })
        case .session(_, let sessionID):
            return Self.makeSummary(from: sessions.filter { $0.id == sessionID })
        }
    }

    func modelBreakdown(for scope: AgentScope) -> [ClaudeCodeModelBreakdown] {
        let source: [ClaudeCodeSessionRecord]
        switch scope {
        case .allProjects: source = sessions
        case .project(let directory): source = sessions.filter { $0.cwd == directory }
        case .session: return []
        }

        return Dictionary(grouping: source) { "\($0.modelProvider)/\($0.model)" }
            .compactMap { _, sessions in
                guard let first = sessions.first else { return nil }
                return ClaudeCodeModelBreakdown(
                    modelProvider: first.modelProvider,
                    model: first.model,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func providerBreakdown(for scope: AgentScope) -> [ProviderBreakdown] {
        let source: [ClaudeCodeSessionRecord]
        switch scope {
        case .allProjects: source = sessions
        case .project(let directory): source = sessions.filter { $0.cwd == directory }
        case .session: return []
        }

        return Dictionary(grouping: source) { $0.modelProvider }
            .compactMap { provider, sessions in
                ProviderBreakdown(provider: provider, summary: Self.makeSummary(from: sessions))
            }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    static func makeSummary(from sessions: [ClaudeCodeSessionRecord]) -> AgentUsageSummary {
        let inputTokens = reduceOptional(\.inputTokens, sessions: sessions)
        let cacheReadTokens = reduceOptional(\.cacheReadTokens, sessions: sessions)
        let totalTokens = sessions.reduce(0) { $0 + $1.tokensUsed }
        let cacheHitDenominatorTokens = cacheReadTokens == nil ? nil : totalTokens

        return AgentUsageSummary(
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: reduceOptional(\.outputTokens, sessions: sessions),
            reasoningTokens: nil,
            cacheReadTokens: cacheReadTokens,
            cacheHitDenominatorTokens: cacheHitDenominatorTokens,
            cacheWriteTokens: reduceOptional(\.cacheWriteTokens, sessions: sessions),
            requestCount: 0,
            sessionsCount: sessions.count,
            cost: nil,
            lastUpdated: sessions.map(\.updatedAt).max()
        )
    }

    private static func reduceOptional(
        _ keyPath: KeyPath<ClaudeCodeSessionRecord, Int?>,
        sessions: [ClaudeCodeSessionRecord]
    ) -> Int? {
        let values = sessions.compactMap { $0[keyPath: keyPath] }
        guard values.isEmpty == false else { return nil }
        return values.reduce(0, +)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeUsageModelsTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add pulse/Managers/ClaudeCodeUsageModels.swift pulseTests/ClaudeCodeUsageModelsTests.swift
git commit -m "feat: add Claude Code usage models"
```

---

### Task 2: ClaudeCodeUsageQuery — transcript parsing

**Files:**
- Create: `pulse/Managers/ClaudeCodeUsageQuery.swift`
- Test: `pulseTests/ClaudeCodeTranscriptTests.swift`

**Interfaces:**
- Consumes: models from Task 1; `agentUsageDayIdentifier(for:)` from `AgentUsageModels.swift`.
- Produces:
  - `enum ClaudeCodeUsageQuery.QueryError: Error, LocalizedError, Equatable` with `case queryStepFailed(message: String)`
  - `static let defaultModelProvider = "Claude"`
  - `static func resolveProjectsDirectory(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL`
  - `static func loadSnapshot(homeDirectoryURL: URL = ..., fileManager: FileManager = .default) throws -> ClaudeCodeUsageSnapshot`
  - `static func loadDailyBuckets(homeDirectoryURL: URL = ..., fileManager: FileManager = .default) throws -> [ClaudeCodeDailyBucket]`

Parsing contract (verified against real transcripts in `~/.claude/projects`):
- `type: "assistant"` lines carry `message.usage` (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`) and `message.model`; top-level `sessionId` or `session_id`, `cwd`, `timestamp` (ISO 8601, often with fractional seconds).
- `type: "ai-title"` lines carry `aiTitle` (may be absent).
- `type: "last-prompt"` lines carry `lastPrompt`.
- Title resolution: last non-empty `aiTitle` → last non-empty `lastPrompt` → cwd basename.
- Model resolution: most frequent `message.model` across assistant messages (session-level attribution — matches `CodexUsageSnapshot.modelBreakdown`, which also uses one model per session).
- `modelProvider` is constant `"Claude"` (transcripts do not record provider).
- requestCount increments once per assistant message that has a `message.usage` dict (including all-zero usage from local models). This is the same definition as OpenCode (`SUM(role = 'assistant' THEN 1)`).
- `totalTokens = input + output + cacheRead + cacheWrite`.
- **`createdAt` = earliest timestamp across ALL lines (session start); `updatedAt` = latest** — mirrors OpenCode's `MIN(s.time_created)` / `MAX(s.time_updated)` and Codex's `created_at_ms`, NOT the first assistant message.
- **Sessions with ≥1 user OR assistant message are included** (tokens may be 0) — matches OpenCode (`LEFT JOIN` with 0-coalesced sums) and Codex (`threads` table). Pure phantom files (only `mode`/`permission-mode` lines, no conversation) are excluded.
- **Single-pass caching:** `loadSnapshot` and `loadDailyBuckets` share one size+mtime cache whose entries store BOTH the buckets and the session accumulator, so each changed transcript is fully parsed exactly once per refresh and unchanged transcripts are metadata-only.
- Malformed/truncated trailing JSON lines are skipped.

- [ ] **Step 1: Write the failing transcript test**

Create `pulseTests/ClaudeCodeTranscriptTests.swift`:

```swift
import XCTest
@testable import Pulse

final class ClaudeCodeTranscriptTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var projectsDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home")
        projectsDir = home.appendingPathComponent(".claude/projects/-Users-tmp-project")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTranscript(_ contents: String, id: String) throws {
        try contents.write(to: projectsDir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    func testLoadSnapshotBuildsSessionRecord() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_1"}
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_1"}
        {"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_1"}
        {"type":"ai-title","aiTitle":"Fix the crash","sessionId":"ses_1"}
        {"type":"last-prompt","lastPrompt":"fix the crash","leafUuid":"a1","sessionId":"ses_1"}
        """, id: "ses_1")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)

        XCTAssertEqual(snapshot.sessions.count, 1)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.id, "ses_1")
        XCTAssertEqual(session.cwd, "/tmp/project")
        XCTAssertEqual(session.model, "claude-sonnet-4")
        XCTAssertEqual(session.modelProvider, "Claude")
        XCTAssertEqual(session.title, "Fix the crash")
        XCTAssertEqual(session.tokensUsed, 135)
        XCTAssertEqual(session.inputTokens, 100)
        XCTAssertEqual(session.outputTokens, 20)
        XCTAssertEqual(session.cacheReadTokens, 10)
        XCTAssertEqual(session.cacheWriteTokens, 5)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:00Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:05Z")!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLoadSnapshotFallsBackToLastPromptTitle() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":1,"output_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_2"}
        {"type":"last-prompt","lastPrompt":"do the thing","leafUuid":"a1","sessionId":"ses_2"}
        """, id: "ses_2")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        XCTAssertEqual(snapshot.sessions.first?.title, "do the thing")
    }

    func testLoadDailyBucketsAggregatesAcrossDaysAndSessions() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_3"}
        {"type":"assistant","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":20,"output_tokens":4,"cache_read_input_tokens":6,"cache_creation_input_tokens":2}},"uuid":"a2","timestamp":"2026-07-22T10:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_3"}
        {"type":"assistant","message":{"id":"m3","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":5,"output_tokens":1}},"uuid":"a3","timestamp":"2026-07-23T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_4"}
        """, id: "ses_3")

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)

        XCTAssertEqual(buckets.count, 2)
        let day = agentUsageDayIdentifier(for: ISO8601DateFormatter().date(from: "2026-07-22T00:00:00Z")!)
        let aggregated = try XCTUnwrap(buckets.first { $0.sessionID == "ses_3" && $0.day == day })
        XCTAssertEqual(aggregated.requestCount, 2)
        XCTAssertEqual(aggregated.inputTokens, 30)
        XCTAssertEqual(aggregated.outputTokens, 6)
        XCTAssertEqual(aggregated.cacheReadTokens, 9)
        XCTAssertEqual(aggregated.cacheWriteTokens, 3)
        XCTAssertEqual(aggregated.totalTokens, 48)
        let second = try XCTUnwrap(buckets.first { $0.sessionID == "ses_4" })
        XCTAssertEqual(second.requestCount, 1)
        XCTAssertEqual(second.totalTokens, 6)
    }

    func testLoadDailyBucketsIgnoresMalformedTail() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_5"}
        {"type":"assistant","message":{"id": "m2", "truncated
        """, id: "ses_5")

        let buckets = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.requestCount, 1)
    }

    func testLoadSnapshotIncludesZeroTokenUserOnlySession() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_6"}
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"never answered"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_6"}
        {"type":"last-prompt","lastPrompt":"never answered","leafUuid":"u1","sessionId":"ses_6"}
        """, id: "ses_6")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.id, "ses_6")
        XCTAssertEqual(session.tokensUsed, 0)
        XCTAssertEqual(session.title, "never answered")
    }

    func testLoadSnapshotIgnoresPhantomFilesWithNoConversation() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_7"}
        {"type":"permission-mode","permissionMode":"default","sessionId":"ses_7"}
        """, id: "ses_7")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testLoadSnapshotCreatedAtIsSessionStartNotFirstAssistantMessage() throws {
        try writeTranscript("""
        {"type":"mode","mode":"normal","sessionId":"ses_8"}
        {"type":"user","message":{"role":"user","content":"typed first"},"uuid":"u1","timestamp":"2026-07-22T08:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_8"}
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":1,"output_tokens":1}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_8"}
        """, id: "ses_8")

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T08:00:00Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-07-22T09:00:05Z")!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSecondLoadReusesCacheWhenTranscriptsUnchanged() throws {
        try writeTranscript("""
        {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_9"}
        """, id: "ses_9")

        _ = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)
        _ = try ClaudeCodeUsageQuery.loadDailyBuckets(homeDirectoryURL: home, fileManager: .default)

        let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
        XCTAssertEqual(snapshot.sessions.map(\.id), ["ses_9"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeTranscriptTests`
Expected: FAIL — `cannot find type 'ClaudeCodeUsageQuery' in scope`.

- [ ] **Step 3: Create `pulse/Managers/ClaudeCodeUsageQuery.swift`**

```swift
import Foundation

enum ClaudeCodeUsageQuery {
    enum QueryError: Error, LocalizedError, Equatable {
        case queryStepFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .queryStepFailed(let message): return message
            }
        }
    }

    static let defaultModelProvider = "Claude"

    static func resolveProjectsDirectory(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    static func loadSnapshot(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> ClaudeCodeUsageSnapshot {
        let entries = try loadCachedEntries(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var sessionsByID: [String: SessionAccumulator] = [:]

        for entry in entries {
            sessionsByID[entry.sessionID, default: SessionAccumulator()].merge(entry.accumulator)
        }

        return ClaudeCodeUsageSnapshot(
            sessions: sessionsByID.compactMap { sessionID, accumulator in
                accumulator.sessionRecord(id: sessionID)
            }
        )
    }

    static func loadDailyBuckets(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> [ClaudeCodeDailyBucket] {
        let entries = try loadCachedEntries(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var totalsBySessionAndDay: [String: ClaudeCodeDailyBucket] = [:]

        for entry in entries {
            merge(entry.buckets, into: &totalsBySessionAndDay)
        }

        return totalsBySessionAndDay
            .compactMap { key, bucket in
                let parts = key.split(separator: "::", maxSplits: 1).map(String.init)
                guard parts.count == 2, let day = Int(parts[1]) else { return nil }
                return ClaudeCodeDailyBucket(
                    sessionID: parts[0],
                    day: day,
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    cacheWriteTokens: bucket.cacheWriteTokens,
                    totalTokens: bucket.totalTokens,
                    requestCount: bucket.requestCount,
                    latestActivityAt: bucket.latestActivityAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.day == rhs.day { return lhs.sessionID < rhs.sessionID }
                return lhs.day < rhs.day
            }
    }

    // MARK: - Cached transcript loading

    private struct ParsedTranscript {
        let sessionID: String
        let accumulator: SessionAccumulator
        let buckets: [ClaudeCodeDailyBucket]
    }

    // Single-pass design: each changed transcript is fully parsed exactly once per
    // refresh, producing both its session accumulator and its daily buckets, which
    // are cached together keyed by size+mtime. Unchanged transcripts are metadata-only.
    private static func loadCachedEntries(
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> [ParsedTranscript] {
        let transcriptURLs = candidateTranscriptURLs(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var cache = DailyBucketCache.load(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var didUpdateCache = false
        var parsed: [ParsedTranscript] = []

        for url in transcriptURLs {
            guard let metadata = TranscriptCacheMetadata(url: url) else {
                if let entry = try parseTranscript(transcriptURL: url) {
                    parsed.append(entry)
                }
                continue
            }

            if let cached = cache.entry(for: metadata) {
                if let sessionID = cached.sessionID, let session = cached.session {
                    parsed.append(ParsedTranscript(sessionID: sessionID, accumulator: session, buckets: cached.buckets))
                }
                continue
            }

            guard let entry = try parseTranscript(transcriptURL: url) else { continue }
            parsed.append(entry)
            cache.setEntry(
                DailyBucketCache.Entry(
                    metadata: metadata,
                    buckets: entry.buckets,
                    sessionID: entry.sessionID,
                    session: entry.accumulator
                ),
                for: metadata.path
            )
            didUpdateCache = true
        }

        if cache.removeEntries(excluding: Set(transcriptURLs.map(\.path))) {
            didUpdateCache = true
        }
        if didUpdateCache {
            cache.save(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        }

        return parsed
    }

    // MARK: - Transcript parsing

    private struct SessionAccumulator: Codable {
        var cwd = ""
        var title: String?
        var lastPrompt: String?
        var modelCounts: [String: Int] = [:]
        var createdAt: Date?
        var updatedAt: Date?
        var totalTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var hasConversation = false

        mutating func merge(_ other: SessionAccumulator) {
            if cwd.isEmpty { cwd = other.cwd }
            if other.title?.isEmpty == false { title = other.title }
            if other.lastPrompt?.isEmpty == false { lastPrompt = other.lastPrompt }
            for (model, count) in other.modelCounts {
                modelCounts[model, default: 0] += count
            }
            if let createdAt = other.createdAt, self.createdAt == nil || createdAt < self.createdAt! {
                self.createdAt = createdAt
            }
            if let updatedAt = other.updatedAt, updatedAt > (self.updatedAt ?? .distantPast) {
                self.updatedAt = updatedAt
            }
            totalTokens += other.totalTokens
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cacheReadTokens += other.cacheReadTokens
            cacheWriteTokens += other.cacheWriteTokens
            hasConversation = hasConversation || other.hasConversation
        }

        func sessionRecord(id: String) -> ClaudeCodeSessionRecord? {
            guard hasConversation else { return nil }
            let resolvedTitle = title?.isEmpty == false
                ? title!
                : (lastPrompt?.isEmpty == false ? lastPrompt! : URL(fileURLWithPath: cwd).lastPathComponent)
            let resolvedModel = modelCounts.max { $0.value < $1.value }?.key ?? ""
            let createdAt = createdAt ?? .distantPast
            return ClaudeCodeSessionRecord(
                id: id,
                title: resolvedTitle,
                cwd: cwd,
                model: resolvedModel,
                modelProvider: ClaudeCodeUsageQuery.defaultModelProvider,
                tokensUsed: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                createdAt: createdAt,
                updatedAt: updatedAt ?? createdAt
            )
        }
    }

    private static func parseTranscript(transcriptURL: URL) throws -> ParsedTranscript? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else {
            throw QueryError.queryStepFailed(message: "Failed to read transcript at \(transcriptURL.path)")
        }
        defer { try? handle.close() }

        guard let contents = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }

        var sessionID: String?
        var accumulator = SessionAccumulator()
        var bucketsByKey: [String: ClaudeCodeDailyBucket] = [:]

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let rawObject = try? JSONSerialization.jsonObject(with: data),
                  let object = rawObject as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            if sessionID == nil {
                sessionID = (object["sessionId"] as? String) ?? (object["session_id"] as? String)
            }

            if type == "ai-title", let aiTitle = object["aiTitle"] as? String, aiTitle.isEmpty == false {
                accumulator.title = aiTitle
                continue
            }

            if type == "last-prompt", let lastPrompt = object["lastPrompt"] as? String, lastPrompt.isEmpty == false {
                accumulator.lastPrompt = lastPrompt
                continue
            }

            // createdAt/updatedAt track the whole transcript (session start), mirroring
            // OpenCode's MIN(s.time_created) / MAX(s.time_updated) and Codex's created_at_ms.
            let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
            if let timestamp {
                if accumulator.createdAt == nil || timestamp < accumulator.createdAt! {
                    accumulator.createdAt = timestamp
                }
                if accumulator.updatedAt == nil || timestamp > accumulator.updatedAt! {
                    accumulator.updatedAt = timestamp
                }
            }

            if type == "user",
               let message = object["message"] as? [String: Any],
               (message["role"] as? String) == "user" {
                accumulator.hasConversation = true
                if accumulator.cwd.isEmpty, let cwd = object["cwd"] as? String {
                    accumulator.cwd = cwd
                }
                continue
            }

            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let currentSessionID = sessionID,
                  let timestamp else {
                continue
            }

            if accumulator.cwd.isEmpty, let cwd = object["cwd"] as? String {
                accumulator.cwd = cwd
            }
            if let model = message["model"] as? String, model.isEmpty == false {
                accumulator.modelCounts[model, default: 0] += 1
            }

            let input = int(usage, "input_tokens") ?? 0
            let output = int(usage, "output_tokens") ?? 0
            let cacheRead = int(usage, "cache_read_input_tokens") ?? 0
            let cacheWrite = int(usage, "cache_creation_input_tokens") ?? 0
            let total = input + output + cacheRead + cacheWrite

            accumulator.hasConversation = true
            accumulator.totalTokens += total
            accumulator.inputTokens += input
            accumulator.outputTokens += output
            accumulator.cacheReadTokens += cacheRead
            accumulator.cacheWriteTokens += cacheWrite

            let day = agentUsageDayIdentifier(for: timestamp)
            let key = "\(currentSessionID)::\(day)"
            let deltaBucket = ClaudeCodeDailyBucket(
                sessionID: currentSessionID,
                day: day,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                totalTokens: total,
                requestCount: 1,
                latestActivityAt: timestamp
            )
            let existing = bucketsByKey[key, default: .zero(sessionID: currentSessionID, day: day)]
            bucketsByKey[key] = existing.merging(deltaBucket)
        }

        guard let sessionID else { return nil }
        return ParsedTranscript(
            sessionID: sessionID,
            accumulator: accumulator,
            buckets: Array(bucketsByKey.values)
        )
    }

    private static func merge(
        _ buckets: some Sequence<ClaudeCodeDailyBucket>,
        into totalsBySessionAndDay: inout [String: ClaudeCodeDailyBucket]
    ) {
        for bucket in buckets {
            let key = "\(bucket.sessionID)::\(bucket.day)"
            let existing = totalsBySessionAndDay[key, default: .zero(sessionID: bucket.sessionID, day: bucket.day)]
            totalsBySessionAndDay[key] = existing.merging(bucket)
        }
    }

    private static func int(_ object: [String: Any], _ key: String) -> Int? {
        (object[key] as? NSNumber)?.intValue
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        ISO8601DateFormatter.claudeCodeUsage.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: - Transcript discovery

    private static func candidateTranscriptURLs(homeDirectoryURL: URL, fileManager: FileManager) -> [URL] {
        var urls: [URL] = []
        collectTranscriptURLs(
            in: resolveProjectsDirectory(homeDirectoryURL: homeDirectoryURL),
            fileManager: fileManager,
            depth: 0,
            maxDepth: 2,
            into: &urls
        )
        return urls
    }

    private static func collectTranscriptURLs(
        in directory: URL,
        fileManager: FileManager,
        depth: Int,
        maxDepth: Int,
        into urls: inout [URL]
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard depth < maxDepth else { continue }
                collectTranscriptURLs(in: url, fileManager: fileManager, depth: depth + 1, maxDepth: maxDepth, into: &urls)
                continue
            }
            if url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
    }

    // MARK: - Cache

    private struct TranscriptCacheMetadata: Codable, Equatable {
        let path: String
        let size: Int
        let modificationTime: TimeInterval

        init?(url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modificationDate = values.contentModificationDate else {
                return nil
            }
            self.path = url.path
            self.size = size
            self.modificationTime = modificationDate.timeIntervalSince1970
        }
    }

    private struct DailyBucketCache: Codable {
        struct Entry: Codable {
            let metadata: TranscriptCacheMetadata
            let buckets: [ClaudeCodeDailyBucket]
            let sessionID: String?
            let session: SessionAccumulator?
        }

        private static let version = 1
        private var version: Int
        private var entriesByPath: [String: Entry]

        static func load(homeDirectoryURL: URL, fileManager: FileManager) -> DailyBucketCache {
            guard let data = try? Data(contentsOf: cacheURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)),
                  let cache = try? JSONDecoder().decode(DailyBucketCache.self, from: data),
                  cache.version == version else {
                return DailyBucketCache(version: version, entriesByPath: [:])
            }
            return cache
        }

        func entry(for metadata: TranscriptCacheMetadata) -> Entry? {
            guard let entry = entriesByPath[metadata.path], entry.metadata == metadata else { return nil }
            return entry
        }

        mutating func setEntry(_ entry: Entry, for path: String) {
            entriesByPath[path] = entry
        }

        mutating func removeEntries(excluding paths: Set<String>) -> Bool {
            let originalCount = entriesByPath.count
            entriesByPath = entriesByPath.filter { paths.contains($0.key) }
            return entriesByPath.count != originalCount
        }

        func save(homeDirectoryURL: URL, fileManager: FileManager) {
            let url = Self.cacheURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }

        private static func cacheURL(homeDirectoryURL: URL, fileManager: FileManager) -> URL {
            let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            return baseURL
                .appendingPathComponent("Pulse", isDirectory: true)
                .appendingPathComponent("claude-code-transcript-cache-\(stableHash(homeDirectoryURL.path))-v\(version).json")
        }

        private static func stableHash(_ value: String) -> String {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(hash, radix: 16)
        }
    }
}

private extension ISO8601DateFormatter {
    static let claudeCodeUsage: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeTranscriptTests`
Expected: PASS. Note: `ISO8601DateFormatter.claudeCodeUsage` must be `private extension` scoped in this file so it does not collide with `ISO8601DateFormatter.codexUsage` from `CodexUsageQuery.swift`.

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/ClaudeCodeUsageQuery.swift pulseTests/ClaudeCodeTranscriptTests.swift
git commit -m "feat: add Claude Code transcript query"
```

---

### Task 3: Wire Claude Code through AgentSource, repository, and store state

**Files:**
- Modify: `pulse/Managers/AgentUsageModels.swift`
- Modify: `pulse/Managers/AgentUsageRepository.swift`
- Modify: `pulse/Managers/AgentUsageViewData.swift`
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulseTests/AgentUsageStoreTests.swift` (extend `StubAgentUsageRepository` and `BlockingAgentUsageRepository`; add tests)

**Interfaces:**
- Consumes: `ClaudeCodeUsageQuery` from Task 2.
- Produces (later tasks rely on these): `AgentSource.claudeCode`, `AgentUsageRepositorying.claudeCodeProjectsURL` + `loadClaudeCodeSnapshot()` + `loadClaudeCodeDailyBuckets()`, `AgentUsageLoadedState.claudeCodeSnapshot` + `.claudeCodeDailyBuckets`, `AgentUsageStore.LoadError.claudeCode`, store precomputed dicts `ccBucketsBySession` / `ccMetadataBySession` / `ccSessionsByDirectory`.

- [ ] **Step 1: Write the failing store tests** (append to `pulseTests/AgentUsageStoreTests.swift`)

Add a helper next to the existing `makeCodexSession` helper:

```swift
private func makeClaudeCodeSession(id: String, tokens: Int = 0, cwd: String = "/tmp/project", updatedAt: TimeInterval = 2_000) -> ClaudeCodeSessionRecord {
    ClaudeCodeSessionRecord(
        id: id,
        title: "Claude Session \(id)",
        cwd: cwd,
        model: "sonnet",
        modelProvider: "Claude",
        tokensUsed: tokens,
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadTokens: nil,
        cacheWriteTokens: nil,
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
```

Add these tests:

```swift
func testRefreshLoadsClaudeCodeState() {
    let repository = StubAgentUsageRepository()
    repository.claudeCodeSnapshot = ClaudeCodeUsageSnapshot(sessions: [makeClaudeCodeSession(id: "cc_1", tokens: 222)])
    repository.claudeCodeDailyBuckets = [
        ClaudeCodeDailyBucket(sessionID: "cc_1", day: 100, inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 1, totalTokens: 16, requestCount: 1, latestActivityAt: nil)
    ]
    let store = AgentUsageStore(repository: repository)

    store.refreshAll()

    XCTAssertEqual(store.state.claudeCodeSnapshot.sessions.map(\.id), ["cc_1"])
    XCTAssertEqual(store.state.claudeCodeDailyBuckets.count, 1)
    XCTAssertEqual(repository.claudeCodeLoadCount, 1)
    XCTAssertEqual(repository.claudeCodeBucketLoadCount, 1)
}

func testAvailableSourcesIncludeClaudeCodeWhenProjectsExist() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let projects = root.appendingPathComponent("projects")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = StubAgentUsageRepository()
    repository.openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/missing-opencode.db")
    repository.codexDatabaseURL = URL(fileURLWithPath: "/tmp/missing-codex.db")
    repository.claudeCodeProjectsURL = projects

    let store = AgentUsageStore(repository: repository)
    XCTAssertTrue(store.availableSources.contains(.claudeCode))
}

func testAvailableSourcesExcludeClaudeCodeWhenProjectsMissing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = StubAgentUsageRepository()
    repository.openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/missing-opencode.db")
    repository.codexDatabaseURL = URL(fileURLWithPath: "/tmp/missing-codex.db")
    repository.claudeCodeProjectsURL = root.appendingPathComponent("no-such-projects")

    let store = AgentUsageStore(repository: repository)
    XCTAssertFalse(store.availableSources.contains(.claudeCode))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
Expected: FAIL — compile error, `type 'StubAgentUsageRepository' does not conform to protocol 'AgentUsageRepositorying'` (missing `claudeCodeProjectsURL` / `loadClaudeCode*`) plus `AgentSource.claudeCode` / `AgentUsageLoadedState.claudeCodeSnapshot` not found.

- [ ] **Step 3: `pulse/Managers/AgentUsageModels.swift`** — add the enum case

In `enum AgentSource` (line 3) add the case and to `selectableCases`:

```swift
enum AgentSource: String, CaseIterable, Identifiable, Hashable, Codable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"
    case claudeCode = "claudecode"

    static let selectableCases: [AgentSource] = [.openCode, .codex, .claudeCode]
```

In `var displayName` add `case .claudeCode: return "Claude Code"`.

In `AgentUsageDataSourceDescription.message` (line 395) add a `claudeCodeProjectsURL: URL` parameter and a case:

```swift
static func message(for source: AgentSource, openCodeDatabaseURL: URL, codexDatabaseURL: URL?, claudeCodeProjectsURL: URL) -> String {
    switch source {
    case .all:
        let codexDescription = codexDatabaseURL?.path ?? "Codex state DB not found"
        return "Pulse reads OpenCode usage from \(openCodeDatabaseURL.path), reads Codex session metadata from \(codexDescription), derives Codex token usage from local transcripts under ~/.codex, and reads Claude Code usage from transcripts under \(claudeCodeProjectsURL.path) when you refresh the panel."
    case .openCode:
        return "Pulse reads this agent's local usage data from \(openCodeDatabaseURL.path) when you refresh the panel."
    case .codex:
        let codexDescription = codexDatabaseURL?.path ?? "Codex state DB not found"
        return "Pulse reads Codex session metadata from \(codexDescription) and derives token usage from local transcripts under ~/.codex when you refresh the panel."
    case .claudeCode:
        return "Pulse reads Claude Code token usage from local transcripts under \(claudeCodeProjectsURL.path) when you refresh the panel."
    }
}
```

- [ ] **Step 4: `pulse/Managers/AgentUsageRepository.swift`** — protocol + impl

```swift
protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }
    var claudeCodeProjectsURL: URL { get }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket]
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket]
    func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot
    func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket]
    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail
}

struct AgentUsageRepository: AgentUsageRepositorying {
    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?
    let claudeCodeProjectsURL: URL

    init(
        openCodeDatabaseURL: URL = OpenCodeUsageQuery.resolveDatabaseURL(),
        codexDatabaseURL: URL? = CodexUsageQuery.resolveDatabaseURL(),
        claudeCodeProjectsURL: URL = ClaudeCodeUsageQuery.resolveProjectsDirectory()
    ) {
        self.openCodeDatabaseURL = openCodeDatabaseURL
        self.codexDatabaseURL = codexDatabaseURL
        self.claudeCodeProjectsURL = claudeCodeProjectsURL
    }

    // ... existing methods unchanged ...

    func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot {
        try ClaudeCodeUsageQuery.loadSnapshot(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
    }

    func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket] {
        try ClaudeCodeUsageQuery.loadDailyBuckets(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
    }
}
```

- [ ] **Step 5: `pulse/Managers/AgentUsageViewData.swift`** — loaded state

```swift
struct AgentUsageLoadedState: Equatable {
    let openCodeCumulativeSnapshot: OpenCodeUsageSnapshot
    let openCodeDailyBuckets: [OpenCodeDailyBucket]
    let codexSnapshot: CodexUsageSnapshot
    let codexDailyBuckets: [CodexDailyBucket]
    let claudeCodeSnapshot: ClaudeCodeUsageSnapshot
    let claudeCodeDailyBuckets: [ClaudeCodeDailyBucket]
    let refreshGeneration: Int
    let codexDetailCache: [String: CodexSessionDetailState]

    static let empty = AgentUsageLoadedState(
        openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
        openCodeDailyBuckets: [],
        codexSnapshot: CodexUsageSnapshot(sessions: []),
        codexDailyBuckets: [],
        claudeCodeSnapshot: ClaudeCodeUsageSnapshot(sessions: []),
        claudeCodeDailyBuckets: [],
        refreshGeneration: 0,
        codexDetailCache: [:]
    )
}
```

- [ ] **Step 6: `pulse/Managers/AgentUsageStore.swift`** — state plumbing

1. `RefreshResult` (line 16) — add two fields:
```swift
let claudeCodeSnapshot: ClaudeCodeUsageSnapshot
let claudeCodeDailyBuckets: [ClaudeCodeDailyBucket]
```
2. `LoadError` (line 26) — add a case + branch:
```swift
case claudeCode(ClaudeCodeUsageQuery.QueryError)
// errorDescription: case .claudeCode(let error): return error.errorDescription
```
3. New stored precomputed dictionaries next to the codex ones (line 51):
```swift
private var ccBucketsBySession: [String: [ClaudeCodeDailyBucket]] = [:]
private var ccMetadataBySession: [String: ClaudeCodeSessionRecord] = [:]
private var ccSessionsByDirectory: [String: [String]] = [:]
```
4. `init` (line 71) — pass `claudeCodeProjectsURL: self.repository.claudeCodeProjectsURL` into `makeAvailableSources(...)`.
5. `beginRefresh` (line 357) — add `claudeCodeSnapshot: context.previousState.claudeCodeSnapshot, claudeCodeDailyBuckets: context.previousState.claudeCodeDailyBuckets,` to the `AgentUsageLoadedState(...)`.
6. `ensureCodexDetailLoaded` (two `AgentUsageLoadedState(...)` constructions at lines 128 and 148) — add `claudeCodeSnapshot: state.claudeCodeSnapshot, claudeCodeDailyBuckets: state.claudeCodeDailyBuckets,`.
7. `loadRefreshResult` (line 373) — add locals at the top:
```swift
var claudeCodeSnapshot = context.previousState.claudeCodeSnapshot
var claudeCodeDailyBuckets = context.previousState.claudeCodeDailyBuckets
```
after the codex block, add:
```swift
if context.enabledSources.contains(.claudeCode) {
    do {
        claudeCodeSnapshot = try repository.loadClaudeCodeSnapshot()
        claudeCodeDailyBuckets = try repository.loadClaudeCodeDailyBuckets()
        loadedAnySource = true
    } catch let error as ClaudeCodeUsageQuery.QueryError {
        if firstError == nil { firstError = .claudeCode(error) }
    } catch {
        if firstError == nil { firstError = .claudeCode(.queryStepFailed(message: error.localizedDescription)) }
    }
} else {
    claudeCodeSnapshot = ClaudeCodeUsageSnapshot(sessions: [])
    claudeCodeDailyBuckets = []
}
```
and add both to the `RefreshResult(...)` return.
8. `applyRefreshResult` (line 424) — add claude fields to the state construction and the precomputed dicts:
```swift
ccBucketsBySession = Dictionary(grouping: result.claudeCodeDailyBuckets) { $0.sessionID }
ccMetadataBySession = Dictionary(uniqueKeysWithValues: result.claudeCodeSnapshot.sessions.map { ($0.id, $0) })
ccSessionsByDirectory = Dictionary(grouping: result.claudeCodeSnapshot.sessions) { $0.cwd }
    .mapValues { $0.map(\.id) }
```
9. `replaceStateForTesting` (line 189) — mirror step 8 using the passed-in state's claude fields.
10. `makeAvailableSources` (line 1458) — new parameter and claude check:
```swift
private func makeAvailableSources(openCodeDatabaseURL: URL, codexDatabaseURL: URL?, claudeCodeProjectsURL: URL) -> [AgentSource] {
    var realSources: [AgentSource] = []
    if FileManager.default.fileExists(atPath: openCodeDatabaseURL.path) {
        realSources.append(.openCode)
    }
    if let codexDatabaseURL, FileManager.default.fileExists(atPath: codexDatabaseURL.path) {
        realSources.append(.codex)
    }
    if FileManager.default.fileExists(atPath: claudeCodeProjectsURL.path) {
        realSources.append(.claudeCode)
    }
    if realSources.isEmpty {
        realSources = [.openCode, .codex, .claudeCode]
    }
    if realSources.count >= 2 {
        return [.all] + realSources
    }
    return realSources
}
```
11. `pulseTests/AgentUsageStoreTests.swift` — extend `StubAgentUsageRepository` (line 1983):
```swift
var claudeCodeProjectsURL = URL(fileURLWithPath: "/tmp/.claude/projects")
var claudeCodeSnapshot = ClaudeCodeUsageSnapshot(sessions: [])
var claudeCodeDailyBuckets: [ClaudeCodeDailyBucket] = []
var claudeCodeError: ClaudeCodeUsageQuery.QueryError?
var claudeCodeLoadCount = 0
var claudeCodeBucketLoadCount = 0

func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot {
    claudeCodeLoadCount += 1
    if let claudeCodeError { throw claudeCodeError }
    return claudeCodeSnapshot
}

func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket] {
    claudeCodeBucketLoadCount += 1
    if let claudeCodeError { throw claudeCodeError }
    return claudeCodeDailyBuckets
}
```
and extend `BlockingAgentUsageRepository` (line 2036):
```swift
let claudeCodeProjectsURL = URL(fileURLWithPath: "/tmp/.claude/projects")
func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot {
    ClaudeCodeUsageSnapshot(sessions: [makeClaudeCodeSession(id: "cc_async")])
}
func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket] {
    []
}
```
12. Update every existing `AgentUsageLoadedState(...)` construction in `pulseTests` (e.g. `AgentUsageStoreTests.swift` around line 953) to add `claudeCodeSnapshot: ClaudeCodeUsageSnapshot(sessions: []), claudeCodeDailyBuckets: [],`. Grep `AgentUsageLoadedState(` in `pulseTests/` and fix all call sites.

- [ ] **Step 7: Run the test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
Expected: PASS (all three new tests, no regressions). If an existing test asserts an exact `availableSources` list of 3 elements, update it to the new 4-element list (the only current assertion, line 779, checks `[.codex]` after `setEnabledSources([.codex])`, which still passes).

- [ ] **Step 8: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift pulse/Managers/AgentUsageRepository.swift pulse/Managers/AgentUsageViewData.swift pulse/Managers/AgentUsageStore.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: thread Claude Code source through agent usage store"
```

---

### Task 4: Derived data and `.all`-mode merges

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:** all work stays internal to `AgentUsageStore`. `derivedData(for:)` gains no new parameters; the `.all` merge and the `.claudeCode` single-source paths are extended in place.

- [ ] **Step 1: Write the failing derived-data tests** (append to `pulseTests/AgentUsageStoreTests.swift`)

```swift
func testClaudeCodeSourceDerivedData() {
    let store = AgentUsageStore(repository: StubAgentUsageRepository())
    store.replaceStateForTesting(AgentUsageLoadedState(
        openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
        openCodeDailyBuckets: [],
        codexSnapshot: CodexUsageSnapshot(sessions: []),
        codexDailyBuckets: [],
        claudeCodeSnapshot: ClaudeCodeUsageSnapshot(sessions: [makeClaudeCodeSession(id: "cc_1", tokens: 100)]),
        claudeCodeDailyBuckets: [],
        refreshGeneration: 1,
        codexDetailCache: [:]
    ))
    store.setEnabledSources([.claudeCode])

    let data = store.derivedData(for: AgentUsageSelection(
        source: .claudeCode, timeRange: .allTime, projectDirectory: nil, sessionID: nil, modelGroupBy: .model
    ))

    XCTAssertEqual(data.summary.totalTokens, 100)
    XCTAssertEqual(data.summary.sessionsCount, 1)
    XCTAssertEqual(data.projectOptions.count, 1)
    XCTAssertEqual(data.modelBreakdownRows.count, 1)
    XCTAssertEqual(data.providerBreakdown.count, 1)
}

func testAllModeMergesClaudeCodeSummary() {
    let store = AgentUsageStore(repository: StubAgentUsageRepository())
    store.replaceStateForTesting(AgentUsageLoadedState(
        openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1", tokens: 10)]),
        openCodeDailyBuckets: [],
        codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 20)]),
        codexDailyBuckets: [],
        claudeCodeSnapshot: ClaudeCodeUsageSnapshot(sessions: [makeClaudeCodeSession(id: "cc_1", tokens: 30)]),
        claudeCodeDailyBuckets: [],
        refreshGeneration: 1,
        codexDetailCache: [:]
    ))
    store.setEnabledSources([.openCode, .codex, .claudeCode])

    let data = store.derivedData(for: AgentUsageSelection(
        source: .all, timeRange: .allTime, projectDirectory: nil, sessionID: nil, modelGroupBy: .model
    ))

    XCTAssertEqual(data.summary.totalTokens, 60)
    XCTAssertEqual(data.summary.sessionsCount, 3)
}
```

Check the existing `makeOpenCodeSession(id:tokens:)` / `makeCodexSession(id:tokens:)` helper signatures in `pulseTests/AgentUsageStoreTests.swift` and match them.

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
Expected: FAIL — `testClaudeCodeSourceDerivedData` and `testAllModeMergesClaudeCodeSummary` fail (derived data ignores claude; `data.summary.totalTokens` is 0 / 30).

- [ ] **Step 3: `pulse/Managers/AgentUsageStore.swift`** — `derivedData` (line 214)

Insert after the codex snapshot selection (line 236):
```swift
let claudeCodeSnapshot: ClaudeCodeUsageSnapshot
if state.claudeCodeDailyBuckets.isEmpty {
    claudeCodeSnapshot = filteredClaudeCodeSnapshot(for: selection.dateSelection, interval: interval)
} else {
    claudeCodeSnapshot = aggregatedClaudeCodeSnapshot(interval: interval)
}
```
After `codexSessionsByID` (line 239):
```swift
let claudeCodeSessionsByID = Dictionary(uniqueKeysWithValues: claudeCodeSnapshot.sessions.map { ($0.id, $0) })
```
After `cxLatestBySession` (line 242):
```swift
let ccLatestBySession = claudeCodeLatestActivityBySession(interval: interval, snapshot: claudeCodeSnapshot)
```
After `cxScopeSummary` (line 245):
```swift
let ccScopeSummary = claudeCodeSnapshot.summary(for: scope)
```
Change the two candidate builders (lines 246-261) to also pass `claudeCodeSnapshot: claudeCodeSnapshot`, and add:
```swift
let ccProjectCount: Int
if scope == .allProjects {
    ccProjectCount = Set(claudeCodeSnapshot.sessions.map(\.cwd)).count
} else {
    ccProjectCount = 0
}
```
`baseSummary` (line 272) becomes:
```swift
case .all:
    AgentUsageSummary.merge(AgentUsageSummary.merge(ocScopeSummary, cxScopeSummary), ccScopeSummary)
case .openCode: ocScopeSummary
case .codex: cxScopeSummary
case .claudeCode: ccScopeSummary
```
`enrichedRequestCount` (line 285):
```swift
case .openCode:
    return baseSummary.requestCount
case .codex:
    return codexRequestCountFromBuckets(for: selection, scope: scope)
case .claudeCode:
    return claudeRequestCountFromBuckets(for: selection, scope: scope)
case .all:
    return baseSummary.requestCount
        + codexRequestCountFromBuckets(for: selection, scope: scope)
        + claudeRequestCountFromBuckets(for: selection, scope: scope)
```
Thread `claudeCodeSnapshot`, `ccScopeSummary`, `ccProjectCount`, `claudeCodeSessionsByID`, `ccLatestBySession` into every `build*` call in the `AgentUsageDerivedViewData(...)` construction (token flow, activity calendar, project options, session options, context rows, provider breakdown, model breakdown, mapping candidates).

- [ ] **Step 4: `pulse/Managers/AgentUsageStore.swift`** — snapshot helpers

Add after `filteredCodexSnapshot` (line 567):
```swift
private func filteredClaudeCodeSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> ClaudeCodeUsageSnapshot {
    if let preset = selection.preset, interval == nil {
        return state.claudeCodeSnapshot.filtered(to: preset)
    }
    guard let interval else { return state.claudeCodeSnapshot }
    let sessions = state.claudeCodeSnapshot.sessions.filter {
        interval.contains(agentUsageDayIdentifier(for: $0.updatedAt))
    }
    return ClaudeCodeUsageSnapshot(sessions: sessions)
}

private func approximateClaudeCodeActivityDate(for day: Int, relativeTo reference: Date) -> Date {
    let calendar = Calendar.autoupdatingCurrent
    let referenceDay = agentUsageDayIdentifier(for: reference, calendar: calendar)
    let deltaDays = day - referenceDay
    return calendar.date(byAdding: .day, value: deltaDays, to: reference) ?? reference
}
```
Add after `aggregatedCodexSnapshot` (line 550):
```swift
private func aggregatedClaudeCodeSnapshot(interval: Range<Int>?) -> ClaudeCodeUsageSnapshot {
    let records: [ClaudeCodeSessionRecord] = ccBucketsBySession.compactMap { sessionID, buckets in
        guard let session = ccMetadataBySession[sessionID] else { return nil }

        var maxActivity: Date?
        var totalTokens = 0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var hasInRangeBuckets = false
        for b in buckets {
            guard interval.map({ $0.contains(b.day) }) ?? true else { continue }
            hasInRangeBuckets = true
            totalTokens += b.totalTokens; input += b.inputTokens; output += b.outputTokens
            cacheRead += b.cacheReadTokens; cacheWrite += b.cacheWriteTokens
            let d = b.latestActivityAt ?? approximateClaudeCodeActivityDate(for: b.day, relativeTo: session.updatedAt)
            if maxActivity == nil || d > maxActivity! { maxActivity = d }
        }

        guard hasInRangeBuckets else { return nil }

        let updatedAt = maxActivity ?? session.updatedAt

        return ClaudeCodeSessionRecord(
            id: session.id,
            title: session.title,
            cwd: session.cwd,
            model: session.model,
            modelProvider: session.modelProvider,
            tokensUsed: totalTokens,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            createdAt: session.createdAt,
            updatedAt: updatedAt
        )
    }

    return ClaudeCodeUsageSnapshot(sessions: records)
}
```

- [ ] **Step 5: `pulse/Managers/AgentUsageStore.swift`** — derivation helpers (each mirrors the codex equivalent)

Add after `codexLatestActivityBySession` (line 1043):
```swift
private func claudeCodeLatestActivityBySession(
    interval: Range<Int>?,
    snapshot: ClaudeCodeUsageSnapshot
) -> [String: Date] {
    var result: [String: Date] = [:]
    for (sessionID, buckets) in ccBucketsBySession {
        guard let metadata = ccMetadataBySession[sessionID] else { continue }
        for bucket in buckets {
            guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
            let activityAt = bucket.latestActivityAt ?? approximateClaudeCodeActivityDate(for: bucket.day, relativeTo: metadata.updatedAt)
            result[sessionID] = max(result[sessionID] ?? .distantPast, activityAt)
        }
    }
    return result
}
```
Add after `codexRequestCountFromBuckets` (line 940):
```swift
private func claudeRequestCountFromBuckets(
    for selection: AgentUsageSelection,
    scope: AgentScope
) -> Int {
    guard selection.source == .claudeCode || selection.source == .all else { return 0 }
    let interval = dayInterval(for: selection.dateSelection)

    switch scope {
    case .allProjects:
        return ccBucketsBySession.reduce(0) { total, entry in
            var requestCount = 0
            for bucket in entry.value where interval.map({ $0.contains(bucket.day) }) ?? true {
                requestCount += bucket.requestCount
            }
            return total + requestCount
        }
    case .project(let directory):
        let sessionIDs = Set(ccSessionsByDirectory[directory] ?? [])
        return ccBucketsBySession.reduce(0) { total, entry in
            guard sessionIDs.contains(entry.key) else { return total }
            var requestCount = 0
            for bucket in entry.value where interval.map({ $0.contains(bucket.day) }) ?? true {
                requestCount += bucket.requestCount
            }
            return total + requestCount
        }
    case .session(_, let sessionID):
        guard let buckets = ccBucketsBySession[sessionID] else { return 0 }
        var requestCount = 0
        for bucket in buckets where interval.map({ $0.contains(bucket.day) }) ?? true {
            requestCount += bucket.requestCount
        }
        return requestCount
    }
}
```
- [ ] **Step 6: `pulse/Managers/AgentUsageStore.swift`** — `latestActivityDate` (line 962)

Add `claudeCodeSnapshot: ClaudeCodeUsageSnapshot` and `ccLatestBySession: [String: Date]` parameters to the signature. The `.all` case becomes:
```swift
case .all:
    return [
        latestActivityDate(for: .openCode, scope: scope, interval: interval, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, claudeCodeSnapshot: claudeCodeSnapshot, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession, ccLatestBySession: ccLatestBySession),
        latestActivityDate(for: .codex, scope: scope, interval: interval, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, claudeCodeSnapshot: claudeCodeSnapshot, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession, ccLatestBySession: ccLatestBySession),
        latestActivityDate(for: .claudeCode, scope: scope, interval: interval, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, claudeCodeSnapshot: claudeCodeSnapshot, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession, ccLatestBySession: ccLatestBySession)
    ].compactMap { $0 }.max()
```
Add the new case (mirrors codex, no subagent filter):
```swift
case .claudeCode:
    switch scope {
    case .allProjects:
        var maxDate: Date?
        for (_, activityAt) in ccLatestBySession {
            if maxDate == nil || activityAt > maxDate! { maxDate = activityAt }
        }
        return maxDate ?? claudeCodeSnapshot.summary(for: scope).lastUpdated
    case .project(let directory):
        var maxDate: Date?
        for sessionID in ccSessionsByDirectory[directory] ?? [] {
            let activityAt = ccLatestBySession[sessionID] ?? ccMetadataBySession[sessionID]?.updatedAt ?? .distantPast
            if maxDate == nil || activityAt > maxDate! { maxDate = activityAt }
        }
        return maxDate ?? claudeCodeSnapshot.summary(for: scope).lastUpdated
    case .session(_, let sessionID):
        return ccLatestBySession[sessionID] ?? claudeCodeSnapshot.summary(for: scope).lastUpdated
    }
```
Update all callers to pass the two new args (in `derivedData` and in `buildContextRows`).

- [ ] **Step 7: `pulse/Managers/AgentUsageStore.swift`** — project / session options

`buildProjectOptions` (line 594): add `claudeCodeSnapshot: ClaudeCodeUsageSnapshot` param. In `.all`, union claude dirs and sum claude tokens/sessions (mirror the oc/cx lines):
```swift
let ccProjects = Dictionary(grouping: claudeCodeSnapshot.sessions, by: \.cwd)
let allDirs = Set(ocProjects.keys).union(cxProjects.keys).union(ccProjects.keys)
// inside the map: let ccSessions = ccProjects[dir] ?? []
// totalTokens += ccSessions.reduce(0) { $0 + $1.tokensUsed }
// sessionsCount += ccSessions.count
```
Add the single-source case:
```swift
case .claudeCode:
    return claudeCodeSnapshot.projectOptions.map {
        SearchableSelectorOption(
            id: $0.directory,
            title: $0.shortName,
            subtitle: "\(compact($0.summary.totalTokens)) total tokens • \($0.summary.sessionsCount) sessions • \($0.directory)"
        )
    }
```
`buildSessionOptions` (line 638): add `claudeCodeSnapshot` param. `.all` stays `[]`. Add:
```swift
case .claudeCode:
    guard let projectDirectory = selection.projectDirectory else { return [] }
    return claudeCodeSnapshot.sessionOptions(for: projectDirectory).map {
        let updatedAt = ccLatestBySession[$0.id] ?? $0.updatedAt
        return SearchableSelectorOption(
            id: $0.id,
            title: $0.title,
            subtitle: "\(compact($0.summary.totalTokens)) total tokens • \(shortDateTime(updatedAt)) • \($0.modelDisplayName)"
        )
    }
```
(add `ccLatestBySession: [String: Date]` to `buildSessionOptions`'s params.)

- [ ] **Step 8: `pulse/Managers/AgentUsageStore.swift`** — token flow & calendar

`buildTokenFlowData`, `buildActivityCalendarData`, `tokenFlowTotalsByDay` gain a `claudeCodeSnapshot: ClaudeCodeUsageSnapshot` param. Add a helper after `codexTokenFlowTotals` (line 765):
```swift
private func claudeCodeTokenFlowTotals(
    interval: Range<Int>?,
    snapshot: ClaudeCodeUsageSnapshot
) -> [Int: Int] {
    if state.claudeCodeDailyBuckets.isEmpty == false && snapshot.sessions.isEmpty == false {
        var totals: [Int: Int] = [:]
        for (_, buckets) in ccBucketsBySession {
            for bucket in buckets {
                guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
                totals[bucket.day, default: 0] += bucket.totalTokens
            }
        }
        return totals
    }

    return snapshot.sessions.reduce(into: [:]) { totals, session in
        let day = agentUsageDayIdentifier(for: session.updatedAt)
        totals[day, default: 0] += session.tokensUsed
    }
}
```
`tokenFlowTotalsByDay` body becomes:
```swift
let openCodeTotals = selection.source != .codex && selection.source != .claudeCode
    ? openCodeTokenFlowTotals(interval: nil, snapshot: openCodeSnapshot)
    : [:]
let codexTotals = selection.source != .openCode && selection.source != .claudeCode
    ? codexTokenFlowTotals(interval: nil, snapshot: codexSnapshot)
    : [:]
let claudeCodeTotals = selection.source == .all || selection.source == .claudeCode
    ? claudeCodeTokenFlowTotals(interval: nil, snapshot: claudeCodeSnapshot)
    : [:]

var totalsByDay = openCodeTotals
for (day, value) in codexTotals { totalsByDay[day, default: 0] += value }
for (day, value) in claudeCodeTotals { totalsByDay[day, default: 0] += value }
return totalsByDay
```

- [ ] **Step 9: `pulse/Managers/AgentUsageStore.swift`** — context rows, breakdowns, mapping candidates

`buildContextRows` (line 808): add `claudeCodeSnapshot`, `ccScopeSummary`, `ccProjectCount`, `claudeCodeSessionsByID`, `ccLatestBySession` params. Add a `.claudeCode` case mirroring the `.codex` case (title/fullPath/model/created/lastUpdated rows; allProjects shows projectsCount + sessionsCount + lastUpdated; project shows projectName/fullPath/sessionsCount/lastUpdated). Use `ccProjectCount`, `ccScopeSummary`, `claudeCodeSessionsByID`, `ccLatestBySession`. Also pass the two new args to the existing `latestActivityDate(...)` calls in the `.openCode`/`.codex` branches.

`buildProviderBreakdown` (line 1101): add `claudeCodeSnapshot` param and case:
```swift
case .claudeCode: return claudeCodeSnapshot.providerBreakdown(for: scope)
```
`buildModelBreakdownRows` (line 1120): add `claudeCodeSnapshot` param and case:
```swift
case .claudeCode:
    return claudeCodeSnapshot.modelBreakdown(for: scope).map {
        AgentUsageDetailRow(
            id: "\($0.modelProvider)/\($0.model)",
            title: "\($0.modelProvider) / \($0.model)",
            valueText: compact($0.summary.totalTokens),
            secondaryText: nil
        )
    }
```
`buildAllProviderMappingCandidates` (line 1157) and `buildAllModelMappingCandidates` (line 1201): add `claudeCodeSnapshot` param and append claude candidates from `claudeCodeSnapshot.providerBreakdown(for: scope)` / `claudeCodeSnapshot.modelBreakdown(for: scope)` (mirror how codex candidates are appended).

`derivedData` final wiring: `codexDetailThreadID` stays `selection.source == .codex && selection.isSessionScope ? selection.sessionID : nil` (unchanged — claude has no detail view; the claude session scope renders its rows via `buildContextRows`). `AgentUsageDerivedViewData` gains no new fields.

- [ ] **Step 10: Run the test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
Expected: PASS — `testClaudeCodeSourceDerivedData` and `testAllModeMergesClaudeCodeSummary` pass, plus all prior tests.

- [ ] **Step 11: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: derive Claude Code usage data and merge into All mode"
```

---

### Task 5: View layer + full verification

**Files:**
- Modify: `pulse/Views/AgentUsageView.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

**Interfaces:** consumes `AgentSource.claudeCode`, `AgentUsageRepositorying.claudeCodeProjectsURL`, and the new `AgentUsageDataSourceDescription.message(for:openCodeDatabaseURL:codexDatabaseURL:claudeCodeProjectsURL:)` signature.

- [ ] **Step 1: `pulse/Views/AgentUsageView.swift`**

`dataSourceDescription` (line 140) — pass the new parameter:
```swift
private func dataSourceDescription(for selection: AgentUsageSelection) -> String {
    AgentUsageDataSourceDescription.message(
        for: selection.source,
        openCodeDatabaseURL: agentStore.repository.openCodeDatabaseURL,
        codexDatabaseURL: agentStore.repository.codexDatabaseURL,
        claudeCodeProjectsURL: agentStore.repository.claudeCodeProjectsURL
    )
}
```
`databasePath` (line 148):
```swift
private var databasePath: String {
    switch selection.source {
    case .all:
        let paths = [
            agentStore.repository.openCodeDatabaseURL.path,
            agentStore.repository.codexDatabaseURL?.path,
            agentStore.repository.claudeCodeProjectsURL.path
        ].compactMap { $0 }
        return paths.joined(separator: " + ")
    case .openCode: return agentStore.repository.openCodeDatabaseURL.path
    case .codex: return agentStore.repository.codexDatabaseURL?.path ?? "Codex database not found"
    case .claudeCode: return agentStore.repository.claudeCodeProjectsURL.path
    }
}
```

No other view changes: `AgentSourcePicker`, the settings checkboxes (SettingsView.swift:132), and `visibleSources` iterate `AgentSource.selectableCases` generically, so "Claude Code" appears automatically.

- [ ] **Step 2: Register the two remaining new files in `pulse.xcodeproj/project.pbxproj`** (if not already done in Task 1)

The four files (`ClaudeCodeUsageModels.swift`, `ClaudeCodeUsageQuery.swift`, `ClaudeCodeUsageModelsTests.swift`, `ClaudeCodeTranscriptTests.swift`) must each have a `PBXBuildFile`, a `PBXFileReference`, group membership, and a Sources-build-phase entry — follow the exact recipe in Task 1 Step 2.

- [ ] **Step 3: Build**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
Expected: all tests pass. Investigate any failure before touching code; the most likely surprises are (a) an existing test asserting an exact `availableSources` list, and (b) any remaining `AgentUsageLoadedState(...)` call site missing the two claude arguments.

- [ ] **Step 5: Sanity-check against real Claude Code data**

Temporarily run the app (or, if a debug hook exists, exercise `AgentUsageStore` with the real repository) and confirm the Agent Usage tab shows a "Claude Code" source when `~/.claude/projects` exists. Do not commit debug scaffolding.

- [ ] **Step 6: Commit**

```bash
git add pulse/Views/AgentUsageView.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: surface Claude Code in agent usage view"
```

- [ ] **Step 7: Update `AGENTS.md`** — add Claude Code facts under "Agent Usage Data Source Facts" (transcripts under `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`; per-assistant-message `usage`; `modelProvider` constant `"Claude"`; no DB). Commit:

```bash
git add AGENTS.md
git commit -m "docs: document Claude Code agent usage data source"
```

---

## Self-Review Checklist

- [ ] Spec coverage: every `.all`-mode merge path (`derivedData` summary, token flow, activity calendar, project options, session options, context rows, provider/model breakdown, mapping candidates, latestActivityDate) has a `.claudeCode` branch and includes claude in `.all`.
- [ ] Availability: `makeAvailableSources` exposes `.claudeCode` only when `~/.claude/projects` exists (dir-exists mirrors the OpenCode/Codex file-exists predicate; the no-source fallback is `[.openCode, .codex, .claudeCode]`, matching the Codex-addition precedent).
- [ ] Cache: `loadSnapshot` and `loadDailyBuckets` share ONE size+mtime cache storing buckets + session accumulator; each changed transcript is fully parsed exactly once per refresh; unchanged transcripts are metadata-only.
- [ ] Session inclusion: sessions with ≥1 user OR assistant message are kept (tokens may be 0), matching OpenCode's 0-coalesced LEFT JOIN and Codex's `threads` table; only phantom files (no conversation) are dropped.
- [ ] `createdAt` = earliest timestamp across all transcript lines (session start), mirroring OpenCode `MIN(time_created)` / Codex `created_at_ms`.
- [ ] `requestCount` semantics: 1 per assistant message with a `usage` dict — identical to OpenCode's `SUM(role='assistant' THEN 1)`; `.all` sums assistant-turn counts per source (existing accepted behavior).
- [ ] Model attribution is session-level (most frequent `message.model`), matching `CodexUsageSnapshot.modelBreakdown`; documented as a known limitation.
- [ ] Session record ids: `sessionRecord(id:)` receives the parsed `sessionID` — no empty ids (grilling catch).
- [ ] Local-day bucketing: `agentUsageDayIdentifier(for:)` used everywhere (no 86400 math).
- [ ] Performance: no linear scans of raw bucket arrays; all claude paths use `ccBucketsBySession` / `ccMetadataBySession` / `ccSessionsByDirectory`.
- [ ] Type consistency: `ClaudeCodeSessionRecord`/`ClaudeCodeDailyBucket`/`ClaudeCodeUsageSnapshot` names and members match across Tasks 1–5; `ccLatestBySession` (not `claudeLatestBySession`) is the store's dict name everywhere.
- [ ] Placeholders: none — every code step has concrete code.
