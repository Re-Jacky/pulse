# Claude Session Manager + Label — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Rename the Agent Usage tab label from "Claude Code" to "Claude". (2) Add Claude Code session support to the Session Manager sidebar (list, filter, transcript viewing, resume), mirroring the existing Codex support.

**Architecture:** Change 1 is a one-line `AgentSource.displayName` change. Change 2 wires Claude through the same seams Codex uses: `SessionManagerSourceFilter` gains a case; `SessionManagementRepository` gains claude load closures and a `loadManagedSessions` branch (mapping `ClaudeCodeUsageSnapshot` → `ManagedSessionSummary`, resolving the main transcript URL); `SessionManagementStore` stops filtering `.claudeCode` out; `SessionListSidebarView` gains `.claudeCode` branches; and `ClaudeCodeUsageQuery` gains a `loadTranscript` that reads user/assistant text turns, plus a `transcriptURL` field on `ClaudeCodeSessionRecord` so the main transcript file is resolvable per session. Resume uses `claude --resume <sessionId>` (branch already exists and is now reachable).

**Tech Stack:** Swift 5.9+, macOS 14.0+, AppKit + SwiftUI, Foundation `JSONSerialization`, no new dependencies.

---

## Global Constraints

- No new dependencies. Only Apple frameworks.
- Follow the `CodexSessionRecord`/`CodexUsageQuery.loadTranscript` patterns exactly for the claude analog (no subagent filtering — every claude session is top-level; subagent transcripts share the parent sessionId and are merged by `loadSnapshot`).
- `transcriptURL` on a `ClaudeCodeSessionRecord` must resolve to the MAIN transcript file (`<encoded-cwd>/<sessionId>.jsonl`), never the `subagents/agent-*.jsonl` file.
- Session manager matching uses rawValue equality (`session.source.rawValue == selectedSourceFilter.rawValue`), so `SessionManagerSourceFilter.claudeCode` must have the same rawValue as `AgentSource.claudeCode` (`"claudecode"`).
- Keep the `ResumeAction.claudeCode(command:)` case (already exists and is handled by `SessionTranscriptDetailView`); do not reuse `.codex(command:)` for claude.
- Every new Swift file must be added to `pulse.xcodeproj/project.pbxproj` (no new files expected beyond tests; new test files via pbxproj direct edit, IDs `1000000000000000000000F0`/`F1` if a new test file is created).
- TDD: no production code without a failing test first.
- Existing session-management tests must not be loosened; where a loadingSources assertion changes, it changes only because `.claudeCode` legitimately joins the loaded-source set.

---

### Task 1: Rename the Agent Usage tab label to "Claude"

**Files:**
- Modify: `pulse/Managers/AgentUsageModels.swift` (`AgentSource.displayName`)
- Test: `pulseTests/ClaudeCodeUsageModelsTests.swift`

**Interfaces:** `AgentSource.claudeCode.displayName` becomes `"Claude"`. The tab label (`AgentSourcePicker`), the settings toggle (`SettingsView`), and mapping-panel source prefixes all read `displayName`, so one change covers them.

- [ ] **Step 1: Write the failing test** (append to `pulseTests/ClaudeCodeUsageModelsTests.swift`)

```swift
func testClaudeCodeSourceDisplayNameIsClaude() {
    XCTAssertEqual(AgentSource.claudeCode.displayName, "Claude")
    XCTAssertTrue(AgentSource.selectableCases.contains(.claudeCode))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeUsageModelsTests`
Expected: FAIL — `XCTAssertEqual` shows `"Claude Code"` vs `"Claude"`.

- [ ] **Step 3: Change `pulse/Managers/AgentUsageModels.swift:18`**

```swift
case .claudeCode: return "Claude"
```

- [ ] **Step 4: Run to verify it passes**

Run: the same focused command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift pulseTests/ClaudeCodeUsageModelsTests.swift
git commit -m "feat: label Claude source as Claude"
```

---

### Task 2: Resolve the main transcript URL per Claude session

**Files:**
- Modify: `pulse/Managers/ClaudeCodeUsageModels.swift` (`ClaudeCodeSessionRecord` gains `transcriptURL`)
- Modify: `pulse/Managers/ClaudeCodeUsageQuery.swift` (`SessionAccumulator` + `parseTranscript` + `sessionRecord`)
- Modify: `pulse/Managers/AgentUsageStore.swift` (`aggregatedClaudeCodeSnapshot` passes `transcriptURL` through)
- Test: `pulseTests/ClaudeCodeTranscriptTests.swift`

**Interfaces (consumed by Task 4):** `ClaudeCodeSessionRecord.transcriptURL: URL?` (default `nil` in the memberwise init so existing constructions compile). `SessionAccumulator.transcriptURL` set ONLY when the parsed file is the main transcript (`url.lastPathComponent == "<sessionId>.jsonl"`), so subagent files never override it.

- [ ] **Step 1: Write the failing test** (append to `pulseTests/ClaudeCodeTranscriptTests.swift`)

```swift
func testLoadSnapshotResolvesMainTranscriptURLNotSubagent() throws {
    let mainURL = projectsDir.appendingPathComponent("ses_url.jsonl")
    let mainTranscript = """
    {"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_url"}
    {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":10,"output_tokens":2}},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_url"}
    """
    try mainTranscript.write(to: mainURL, atomically: true, encoding: .utf8)

    let sessionDir = projectsDir.appendingPathComponent("ses_url")
    let subagentsDir = sessionDir.appendingPathComponent("subagents")
    try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
    let subagent = """
    {"type":"assistant","isSidechain":true,"agentId":"agent-x","message":{"id":"m2","type":"message","role":"assistant","model":"opus","usage":{"input_tokens":5,"output_tokens":1}},"uuid":"a2","timestamp":"2026-07-22T09:01:05.000Z","cwd":"/tmp/project","sessionId":"ses_url"}
    """
    try subagent.write(to: subagentsDir.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageQuery.loadSnapshot(homeDirectoryURL: home, fileManager: .default)
    let session = try XCTUnwrap(snapshot.sessions.first)
    XCTAssertEqual(session.transcriptURL?.standardizedFileURL, mainURL.standardizedFileURL)
    XCTAssertEqual(session.tokensUsed, 18)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeTranscriptTests`
Expected: FAIL — `session.transcriptURL` is `nil` (compile error if the field doesn't exist yet; add the field with default nil first, then it fails on the assertion).

- [ ] **Step 3: `pulse/Managers/ClaudeCodeUsageModels.swift`** — add the field

In `ClaudeCodeSessionRecord` add `let transcriptURL: URL?` and a `transcriptURL: URL? = nil` parameter (last param) in the init, assigned in the body.

- [ ] **Step 4: `pulse/Managers/ClaudeCodeUsageQuery.swift`**

In `SessionAccumulator` add `var transcriptURL: URL?` and in `merge(_:)` add:
```swift
if transcriptURL == nil { transcriptURL = other.transcriptURL }
```
In `parseTranscript` — after `guard let sessionID else { return nil }`, set the main-file URL before returning. `parseTranscript` currently does not receive the file URL; add a `transcriptURL: URL` parameter, and pass it from `loadCachedEntries` (both the fresh-parse call and the cache-hit reconstruction):
```swift
// main transcript lives at <dir>/<sessionID>.jsonl; subagent files are
// agent-*.jsonl under a subagents/ dir and must NOT claim the URL
if url.lastPathComponent == "\(sessionID).jsonl" {
    accumulator.transcriptURL = url
}
```
In `SessionAccumulator.sessionRecord(id:)` set `transcriptURL: transcriptURL` on the record.

In `loadCachedEntries`, pass `transcriptURL: url` into `parseTranscript`, and in the cache-hit branch set `session.transcriptURL` to the cached value (the cached `SessionAccumulator` already carries it).

- [ ] **Step 5: `pulse/Managers/AgentUsageStore.swift`** — `aggregatedClaudeCodeSnapshot` passes the URL through

Add `transcriptURL: session.transcriptURL` to the `ClaudeCodeSessionRecord(...)` it builds.

- [ ] **Step 6: Run to verify it passes**

Run the focused test. Expected: PASS. Then run the full claude transcript suite.

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/ClaudeCodeUsageModels.swift pulse/Managers/ClaudeCodeUsageQuery.swift pulse/Managers/AgentUsageStore.swift pulseTests/ClaudeCodeTranscriptTests.swift
git commit -m "feat: resolve main transcript URL per Claude session"
```

---

### Task 3: Claude transcript loader (session-manager turn extraction)

**Files:**
- Modify: `pulse/Managers/ClaudeCodeUsageQuery.swift` (add `loadTranscript`)
- Test: `pulseTests/ClaudeCodeTranscriptTests.swift`

**Interfaces (consumed by Task 4):** `static func loadTranscript(sessionID: String, transcriptURL: URL?, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default, onPartialUpdate: (@Sendable ([TranscriptTurn]) -> Void)? = nil) throws -> [TranscriptTurn]`. Turn extraction: `type == "user"` with non-meta, non-empty **String** `message.content` → user turn; `type == "assistant"` → assistant turn from the `text` blocks of `message.content` (skip `thinking`/`tool_use`/`tool_result`). Missing file → `QueryError.queryStepFailed`.

- [ ] **Step 1: Write the failing test** (append to `pulseTests/ClaudeCodeTranscriptTests.swift`)

```swift
func testLoadTranscriptExtractsUserAndAssistantTextTurns() throws {
    let transcriptURL = projectsDir.appendingPathComponent("ses_turns.jsonl")
    let transcript = """
    {"type":"user","message":{"role":"user","content":"fix the crash"},"uuid":"u1","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp/project","sessionId":"ses_turns"}
    {"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>meta</local-command-caveat>"},"uuid":"u2","timestamp":"2026-07-22T09:00:01.000Z","cwd":"/tmp/project","sessionId":"ses_turns"}
    {"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"opus","content":[{"type":"thinking","thinking":"plan"},{"type":"text","text":"I found it"},{"type":"tool_use","id":"t1","name":"grep"}]},"uuid":"a1","timestamp":"2026-07-22T09:00:05.000Z","cwd":"/tmp/project","sessionId":"ses_turns"}
    """
    try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

    let turns = try ClaudeCodeUsageQuery.loadTranscript(
        sessionID: "ses_turns",
        transcriptURL: transcriptURL,
        homeDirectoryURL: home,
        fileManager: .default
    )

    XCTAssertEqual(turns.map(\.role), [.user, .assistant])
    XCTAssertEqual(turns.map(\.text), ["fix the crash", "I found it"])
}

func testLoadTranscriptThrowsWhenFileMissing() {
    XCTAssertThrowsError(
        try ClaudeCodeUsageQuery.loadTranscript(sessionID: "missing", transcriptURL: nil, homeDirectoryURL: home, fileManager: .default)
    )
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeTranscriptTests`
Expected: FAIL — `cannot find 'loadTranscript' in scope` / no such member.

- [ ] **Step 3: Add `loadTranscript` to `pulse/Managers/ClaudeCodeUsageQuery.swift`**

```swift
static func loadTranscript(
    sessionID: String,
    transcriptURL: URL? = nil,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    onPartialUpdate: (@Sendable ([TranscriptTurn]) -> Void)? = nil
) throws -> [TranscriptTurn] {
    let url: URL
    if let transcriptURL {
        url = transcriptURL
    } else {
        guard let found = candidateTranscriptURLs(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            .first(where: { $0.lastPathComponent == "\(sessionID).jsonl" }) else {
            throw QueryError.queryStepFailed(message: "No transcript found for session \(sessionID)")
        }
        url = found
    }

    guard let handle = try? FileHandle(forReadingFrom: url) else {
        throw QueryError.queryStepFailed(message: "Failed to read transcript at \(url.path)")
    }
    defer { try? handle.close() }
    guard let contents = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
        return []
    }

    var turns: [TranscriptTurn] = []
    var publishedCount = 0
    let partialBatchSize = 24

    for line in contents.split(whereSeparator: \.isNewline) {
        guard let data = line.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any],
              let type = object["type"] as? String else {
            continue
        }

        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)

        if type == "user",
           (object["isMeta"] as? Bool) != true,
           let message = object["message"] as? [String: Any],
           let content = message["content"] as? String,
           content.isEmpty == false {
            turns.append(TranscriptTurn(id: (object["uuid"] as? String) ?? UUID().uuidString, role: .user, text: content, timestamp: timestamp))
        } else if type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["type"] as? String == "text" ? ($0["text"] as? String) : nil }
                .joined(separator: "\n")
            guard text.isEmpty == false else { continue }
            turns.append(TranscriptTurn(id: (object["uuid"] as? String) ?? UUID().uuidString, role: .assistant, text: text, timestamp: timestamp))
        } else {
            continue
        }

        if let onPartialUpdate, turns.count - publishedCount >= partialBatchSize {
            publishedCount = turns.count
            onPartialUpdate(turns)
        }
    }

    if let onPartialUpdate, turns.count > publishedCount {
        onPartialUpdate(turns)
    }
    return turns
}
```

- [ ] **Step 4: Run to verify it passes**

Run the focused test. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/ClaudeCodeUsageQuery.swift pulseTests/ClaudeCodeTranscriptTests.swift
git commit -m "feat: load Claude session transcript turns"
```

---

### Task 4: Wire Claude into the Session Manager

**Files:**
- Modify: `pulse/Managers/SessionManagementModels.swift` (`SessionManagerSourceFilter`)
- Modify: `pulse/Managers/SessionManagementStore.swift` (refresh, `isLoadingSessions`)
- Modify: `pulse/Managers/SessionManagementRepository.swift` (closures, `loadManagedSessions`, `loadTranscript` ×2)
- Modify: `pulse/Views/SessionListSidebarView.swift` (filter availability, loading/empty messages, source label)
- Test: `pulseTests/SessionManagementStoreTests.swift` (update loadingSources assertions), `pulseTests/ClaudeCodeSessionManagementTests.swift` (create)

**Interfaces:** `SessionManagerSourceFilter.claudeCode = "claudecode"` (rawValue must equal `AgentSource.claudeCode.rawValue`). Managed session id prefix `"claudeCode::"`. Subtitle `"\(modelProvider) / \(model)"` (e.g. `Claude / sonnet`). Resume command `claude --resume <rawSessionID>` (existing branch, now reachable).

- [ ] **Step 1: Write the failing tests**

Create `pulseTests/ClaudeCodeSessionManagementTests.swift` (register in pbxproj with IDs `1000000000000000000000F0`/`F1`):

```swift
import XCTest
@testable import Pulse

final class ClaudeCodeSessionManagementTests: XCTestCase {
    private func makeClaudeSession(id: String, cwd: String, updatedAt: TimeInterval) -> ClaudeCodeSessionRecord {
        ClaudeCodeSessionRecord(
            id: id,
            title: "Claude \(id)",
            cwd: cwd,
            model: "sonnet",
            modelProvider: "Claude",
            tokensUsed: 10,
            inputTokens: 10,
            outputTokens: 0,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")
        )
    }

    func testLoadManagedSessionsIncludesClaudeSessions() throws {
        let repository = SessionManagementRepository(
            resolveOpenCodeDatabaseURL: { URL(fileURLWithPath: "/tmp/missing-opencode.db") },
            loadOpenCodeSnapshot: { _ in OpenCodeUsageSnapshot(sessions: []) },
            loadOpenCodeTranscript: { _, _ in [] },
            loadCodexSnapshot: { CodexUsageSnapshot(sessions: []) },
            loadCodexTranscript: { _, _ in [] },
            loadCodexTranscriptProgressively: { _, _, _ in [] },
            loadClaudeCodeSnapshot: {
                ClaudeCodeUsageSnapshot(sessions: [
                    self.makeClaudeSession(id: "cc_1", cwd: "/tmp/pulse", updatedAt: 2_000)
                ])
            },
            loadClaudeCodeTranscript: { _, _ in [] },
            loadClaudeCodeTranscriptProgressively: { _, _, _ in [] }
        )

        let sessions = try repository.loadManagedSessions(enabledSources: Set([.claudeCode]))
        XCTAssertEqual(sessions.map(\.id), ["claudeCode::cc_1"])
        XCTAssertEqual(sessions.first?.source, .claudeCode)
        XCTAssertEqual(sessions.first?.rawSessionID, "cc_1")
        XCTAssertEqual(sessions.first?.projectPath, "/tmp/pulse")
        XCTAssertEqual(sessions.first?.transcriptURL, URL(fileURLWithPath: "/tmp/cc_1.jsonl"))
    }

    func testResumeActionForClaudeUsesClaudeCommand() throws {
        let repository = SessionManagementRepository()
        let session = ManagedSessionSummary(
            id: "claudeCode::cc_1",
            source: .claudeCode,
            rawSessionID: "cc_1",
            title: "t",
            projectPath: "/tmp",
            projectName: "pulse",
            subtitle: "Claude / sonnet",
            updatedAt: Date(),
            transcriptURL: nil
        )
        XCTAssertEqual(repository.resumeAction(for: session), .claudeCode(command: "claude --resume cc_1"))
    }
}
```

The existing test-file-only `SessionManagementRepository()` convenience init must remain source-compatible — the new claude closures get defaults, and the convenience init passes claude defaults (no new params on the convenience init). If the convenience init signature must change, update `CodexSessionTranscriptTests.swift` call sites accordingly.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/ClaudeCodeSessionManagementTests`
Expected: FAIL — `SessionManagerSourceFilter.claudeCode` / claude closures missing, compile errors, or assertions fail.

- [ ] **Step 3: `pulse/Managers/SessionManagementModels.swift`**

```swift
enum SessionManagerSourceFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"
    case claudeCode = "claudecode"
    // id stays rawValue
}
```

- [ ] **Step 4: `pulse/Managers/SessionManagementStore.swift`**

Remove the `.subtracting([.claudeCode])` filter and its comment (line 56-58) so claude flows through:
```swift
let managedSources = enabledSources
```
Add a `.claudeCode` case to `isLoadingSessions(for:)`:
```swift
case .claudeCode:
    return loadingSources.contains(.claudeCode)
```

- [ ] **Step 5: `pulse/Managers/SessionManagementRepository.swift`**

Add three stored closures + init params (with defaults) mirroring the codex ones:
```swift
private let loadClaudeCodeSnapshot: () throws -> ClaudeCodeUsageSnapshot
private let loadClaudeCodeTranscript: (String, URL?) throws -> [TranscriptTurn]
private let loadClaudeCodeTranscriptProgressively: (String, URL?, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn]
```
Defaults in the designated init:
```swift
loadClaudeCodeSnapshot: @escaping () throws -> ClaudeCodeUsageSnapshot = { try ClaudeCodeUsageQuery.loadSnapshot() },
loadClaudeCodeTranscript: @escaping (String, URL?) throws -> [TranscriptTurn] = {
    try ClaudeCodeUsageQuery.loadTranscript(sessionID: $0, transcriptURL: $1)
},
loadClaudeCodeTranscriptProgressively: @escaping (String, URL?, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn] = {
    try ClaudeCodeUsageQuery.loadTranscript(sessionID: $0, transcriptURL: $1, onPartialUpdate: $2)
}
```
Wire the three new params into the convenience init by passing the claude defaults through (designated-init call) — the convenience init signature stays unchanged so existing tests compile.

In `loadManagedSessions`: add a claude branch mirroring the codex branch (no subagent filter):
```swift
var claudeCodeSessions: [ManagedSessionSummary] = []
var claudeCodeLoaded = false
var claudeCodeError: Error?

if enabledSources.contains(.claudeCode) {
    do {
        claudeCodeSessions = try loadClaudeCodeSnapshot().sessions.map { session in
            ManagedSessionSummary(
                id: "claudeCode::\(session.id)",
                source: .claudeCode,
                rawSessionID: session.id,
                title: session.title,
                projectPath: session.cwd,
                projectName: session.shortProjectName,
                subtitle: "\(session.modelProvider) / \(session.model)",
                updatedAt: session.updatedAt,
                transcriptURL: session.transcriptURL
            )
        }
        claudeCodeLoaded = true
        onPartialUpdate(
            ManagedSessionsPartialUpdate(
                sessions: (openCodeSessions + codexSessions + claudeCodeSessions).sorted { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
                    return lhs.updatedAt > rhs.updatedAt
                },
                loadedSources: Set([
                    openCodeLoaded ? AgentSource.openCode : nil,
                    codexLoaded ? .codex : nil,
                    .claudeCode
                ].compactMap { $0 })
            )
        )
    } catch {
        claudeCodeError = error
    }
}
```
Guard: `guard openCodeLoaded || codexLoaded || claudeCodeLoaded else { throw claudeCodeError ?? codexError ?? openCodeError ?? ... }`. Return combines all three, sorted.

Both `loadTranscript(for:)` overloads: replace the two `.claudeCode` unreachable-comment branches with:
```swift
case .claudeCode:
    return try loadClaudeCodeTranscript(session.rawSessionID, session.transcriptURL)
```
and for the progressive overload:
```swift
case .claudeCode:
    return try loadClaudeCodeTranscriptProgressively(session.rawSessionID, session.transcriptURL, onPartialUpdate)
```
`resumeAction` for `.claudeCode` already returns `.claudeCode(command: "claude --resume \(session.rawSessionID)")` — leave it (now reachable).

- [ ] **Step 6: `pulse/Views/SessionListSidebarView.swift`** — add `.claudeCode` to the four switches

```swift
// filter availability (line ~14):
case .claudeCode: return enabledSources.contains(.claudeCode)
// loadingStateMessage (line ~160):
case .claudeCode: return "Loading Claude sessions..."
// emptyStateMessage (line ~178):
case .claudeCode: return "No Claude sessions found."
// sourceLabel (line ~189):
case .claudeCode: return "Claude"
```

- [ ] **Step 7: Update `pulseTests/SessionManagementStoreTests.swift`**

The loadingSources assertions that currently expect `[.codex]` now legitimately include claude. Set `enabledSources` explicitly in those tests (e.g. `refreshIfNeeded(enabledSources: [.codex])` or update the expected value to `[.codex, .claudeCode]`) so the assertion stays meaningful. Do not loosen other assertions.

- [ ] **Step 8: Run to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests -only-testing:pulseTests/ClaudeCodeSessionManagementTests`
Expected: PASS. Then the full suite + Debug build.

- [ ] **Step 9: Commit**

```bash
git add pulse/Managers/SessionManagementModels.swift pulse/Managers/SessionManagementStore.swift pulse/Managers/SessionManagementRepository.swift pulse/Views/SessionListSidebarView.swift pulseTests/SessionManagementStoreTests.swift pulseTests/ClaudeCodeSessionManagementTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: support Claude sessions in session manager"
```

---

## Self-Review Checklist

- [ ] Tab label: `AgentSource.claudeCode.displayName == "Claude"` (usage tab + settings toggle + mapping prefixes).
- [ ] `transcriptURL` on `ClaudeCodeSessionRecord` is the MAIN transcript, never a `subagents/` file.
- [ ] `SessionManagerSourceFilter.claudeCode.rawValue == AgentSource.claudeCode.rawValue` (`"claudecode"`), so `visibleSessions`/`sessionsForCurrentSource` rawValue matching works.
- [ ] `loadManagedSessions` includes claude; partial updates and the loaded-sources guard include claude.
- [ ] Claude transcript turns: user = non-meta string content; assistant = `text` blocks only; batching for progressive updates.
- [ ] Resume for claude = `claude --resume <id>` (never `.codex`).
- [ ] No subagent filtering on claude sessions; subagent transcripts merged into the parent session by `loadSnapshot`.
- [ ] Full suite + Debug build green.
