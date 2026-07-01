# Session List Updated Timestamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a compact absolute `updatedAt` timestamp on each session row in the session manager sidebar while preserving the current newest-first ordering and compact row layout.

**Architecture:** Keep the change view-local by formatting `ManagedSessionSummary.updatedAt` inside the session list sidebar layer and appending it to the existing metadata line. Extract a small formatting helper with a narrow seam so we can test the timestamp output without introducing heavyweight SwiftUI view tests.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, AppKit/Foundation date formatting

## Global Constraints

- Make recency visible in the session list without adding new controls.
- Preserve the current compact sidebar density.
- Reuse an existing short date/time formatting style used elsewhere in the app.
- Do not change session ordering behavior.
- Do not add user-configurable sorting.
- Do not add a new line or expand row height substantially.
- Do not change session repository or store loading logic.

---

### Task 1: Add and Test Session Row Timestamp Formatting

**Files:**
- Modify: `pulse/Views/SessionListSidebarView.swift`
- Test: `pulseTests/SessionListSidebarViewTests.swift`

**Interfaces:**
- Consumes: `ManagedSessionSummary.updatedAt: Date`
- Produces: `SessionListRowFormatting.metadataText(subtitle: String, updatedAt: Date, formatter: DateFormatter) -> String`

- [ ] **Step 1: Write the failing test**

Create `pulseTests/SessionListSidebarViewTests.swift` with:

```swift
import XCTest
@testable import Pulse

final class SessionListSidebarViewTests: XCTestCase {
    func testMetadataTextAppendsFormattedUpdatedAtTimestamp() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, HH:mm"

        let date = Date(timeIntervalSince1970: 1_783_047_120) // Jul 1, 2026 06:32 UTC

        let text = SessionListRowFormatting.metadataText(
            subtitle: "openai / gpt-5.4",
            updatedAt: date,
            formatter: formatter
        )

        XCTAssertEqual(text, "openai / gpt-5.4 • Jul 1, 06:32")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionListSidebarViewTests`

Expected: FAIL because `SessionListRowFormatting` and `metadataText` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

In `pulse/Views/SessionListSidebarView.swift`, add a small helper near the bottom of the file:

```swift
enum SessionListRowFormatting {
    static func metadataText(subtitle: String, updatedAt: Date, formatter: DateFormatter = shortDateTimeFormatter) -> String {
        "\(subtitle) • \(formatter.string(from: updatedAt))"
    }

    static let shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
```

Update the session subtitle row from:

```swift
Text(session.subtitle)
    .font(.system(size: 11))
    .foregroundColor(.appTertiaryText)
    .lineLimit(1)
```

to:

```swift
Text(SessionListRowFormatting.metadataText(subtitle: session.subtitle, updatedAt: session.updatedAt))
    .font(.system(size: 11))
    .foregroundColor(.appTertiaryText)
    .lineLimit(1)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionListSidebarViewTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pulse/Views/SessionListSidebarView.swift pulseTests/SessionListSidebarViewTests.swift
git commit -m "feat: show updated timestamp in session list"
```

### Task 2: Verify Sidebar Behavior and Guard Against Regression

**Files:**
- Modify: `pulseTests/SessionManagementStoreTests.swift`
- Test: `pulseTests/SessionManagementStoreTests.swift`, `pulseTests/SessionListSidebarViewTests.swift`

**Interfaces:**
- Consumes: `SessionManagementStore.visibleSessions() -> [ManagedSessionSummary]`, `ManagedSessionSummary.updatedAt: Date`
- Produces: Regression coverage confirming the ordering logic remains untouched while the UI gains timestamp visibility

- [ ] **Step 1: Write the failing regression test**

Add this test to `pulseTests/SessionManagementStoreTests.swift`:

```swift
@MainActor
func testVisibleSessionsRemainSortedByNewestUpdatedAtFirst() async {
    let older = makeManagedSession(
        id: "codex::1",
        source: .codex,
        title: "Older",
        projectPath: "/tmp/a",
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let newer = makeManagedSession(
        id: "codex::2",
        source: .codex,
        title: "Newer",
        projectPath: "/tmp/a",
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    let repository = StubSessionManagementRepository(sessions: [older, newer])
    let store = SessionManagementStore(repository: repository)

    store.refreshIfNeeded()
    await fulfillment(of: [repository.loadManagedSessionsExpectation], timeout: 1.0)

    XCTAssertEqual(store.visibleSessions().map(\.id), ["codex::2", "codex::1"])
}
```

If `makeManagedSession` does not currently accept `updatedAt`, extend that helper minimally rather than changing production code.

- [ ] **Step 2: Run tests to verify the new test status**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests -only-testing:pulseTests/SessionListSidebarViewTests`

Expected: If helper support is missing, FAIL until the helper is updated. If the helper already supports `updatedAt`, the new regression test should pass once compiled.

- [ ] **Step 3: Write minimal supporting test implementation**

If needed, update the `makeManagedSession` helper in `pulseTests/SessionManagementStoreTests.swift` to accept an optional `updatedAt` parameter:

```swift
private func makeManagedSession(
    id: String,
    source: AgentSource,
    title: String,
    projectPath: String,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> ManagedSessionSummary {
    ManagedSessionSummary(
        id: id,
        source: source,
        rawSessionID: id.components(separatedBy: "::").last ?? id,
        title: title,
        projectPath: projectPath,
        projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
        subtitle: source == .codex ? "openai / gpt-5.4" : "anthropic / sonnet",
        updatedAt: updatedAt,
        transcriptURL: nil
    )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild clean test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests -only-testing:pulseTests/SessionListSidebarViewTests`

Expected: PASS, confirming the sidebar timestamp formatter is covered and the list ordering behavior is unchanged.

- [ ] **Step 5: Commit**

```bash
git add pulseTests/SessionManagementStoreTests.swift pulseTests/SessionListSidebarViewTests.swift
git commit -m "test: cover session list timestamp and ordering"
```

## Self-Review

### Spec coverage

- Visible recency in session rows: covered by Task 1
- Preserve compact three-line row: covered by Task 1 by appending to existing metadata line
- Reuse short date/time formatting style: covered by Task 1 formatter helper
- Leave ordering unchanged: covered by Task 2 regression test
- No repository/store loading changes: no task modifies repository or loading logic

### Placeholder scan

- No `TODO`, `TBD`, or deferred implementation markers remain
- Each code-changing step includes concrete code
- Each verification step includes a concrete command and expected result

### Type consistency

- Formatter helper returns `String`
- Helper consumes `subtitle: String` and `updatedAt: Date`
- Regression test continues to use `ManagedSessionSummary.updatedAt: Date`

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-01-session-list-updated-at-implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
