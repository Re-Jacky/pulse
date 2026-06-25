# Codex Subagent Status Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Codex subagents stop appearing as standalone live sessions in Pulse while still allowing active Codex child work to keep the parent session in `working`.

**Architecture:** Normalize Codex child-session metadata at the hook boundary so emitted events match the shared `PulseAgentStatusEvent` contract already used by OpenCode. Then verify the shared `AgentStatusStore` continues to aggregate child activity into the parent without adding a Codex-specific slot model.

**Tech Stack:** Swift 5.9, AppKit/Swift model layer, shell hook generation, Node-in-shell payload normalization, XCTest, Xcode project

---

## File Structure

- Modify: `pulse/Managers/CodexIntegrationInstaller.swift`
  - Tighten Codex hook payload normalization so child events emit stable `parentSessionID` and `isSubagent` only when the relationship is valid
- Modify: `pulseTests/AgentIntegrationManagerTests.swift`
  - Add regression coverage for Codex hook script content around parent normalization and child classification
- Modify: `pulseTests/PulseAgentStatusServerTests.swift`
  - Add Codex live-event aggregation coverage proving child sessions do not surface as standalone slots

### Task 1: Add Failing Codex Subagent Regression Tests

**Files:**
- Modify: `pulseTests/AgentIntegrationManagerTests.swift`
- Modify: `pulseTests/PulseAgentStatusServerTests.swift`

- [ ] **Step 1: Add a failing installer test for Codex parent normalization**

Add this test to `pulseTests/AgentIntegrationManagerTests.swift`:

```swift
func testCodexHookNormalizesOnlyRealParentSessionsAsSubagents() throws {
    let fs = InMemoryAgentIntegrationFileSystem()
    let installer = CodexIntegrationInstaller(
        fileSystem: fs,
        homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
    )

    try installer.install()

    let hook = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights-hook.sh"))
    XCTAssertTrue(hook.contains("function normalizeParentSessionID"))
    XCTAssertTrue(hook.contains("parentSessionID.startsWith(\"thread_\")"))
    XCTAssertTrue(hook.contains("const normalizedParentSessionID = normalizeParentSessionID(parentSessionID);"))
    XCTAssertTrue(hook.contains("const isSubagent = normalizedParentSessionID.length > 0 && eventName.startsWith(\"Subagent\");"))
    XCTAssertTrue(hook.contains("...(normalizedParentSessionID.length > 0 ? { parentSessionID: normalizedParentSessionID } : {})"))
}
```

- [ ] **Step 2: Add a failing Codex aggregation server test**

Add this test to `pulseTests/PulseAgentStatusServerTests.swift`:

```swift
@MainActor
func testHandlePayloadAggregatesCodexSubagentIntoParentSession() throws {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.codex]
    )
    let server = PulseAgentStatusServer(store: store)
    let parentPayload = """
    {"agent":"codex","sessionID":"thread_parent","projectPath":"/tmp/pulse","title":"Parent","timestamp":"1970-01-01T00:01:40Z","kind":"session.idle"}
    """.data(using: .utf8)!
    let childPayload = """
    {"agent":"codex","sessionID":"thread_child","projectPath":"/tmp/pulse","title":"Child","timestamp":"1970-01-01T00:01:41Z","kind":"session.working","parentSessionID":"thread_parent","isSubagent":true}
    """.data(using: .utf8)!

    try server.handlePayload(parentPayload)
    try server.handlePayload(childPayload)

    XCTAssertEqual(store.groups[0].slots.count, 1)
    XCTAssertEqual(store.groups[0].slots.first?.sessionID, "thread_parent")
    XCTAssertEqual(store.groups[0].slots.first?.state, .working)
    XCTAssertEqual(store.groups[0].slots.first?.sessionState, .idle)
}
```

- [ ] **Step 3: Add a failing Codex subagent-idle fallback test**

Add this test to `pulseTests/PulseAgentStatusServerTests.swift`:

```swift
@MainActor
func testHandlePayloadLetsCodexParentReturnToBaseStateAfterChildStops() throws {
    let store = AgentStatusStore(
        persistence: InMemoryAgentStatusPersistence(),
        enabledAgents: [.codex]
    )
    let server = PulseAgentStatusServer(store: store)
    let parentPayload = """
    {"agent":"codex","sessionID":"thread_parent","projectPath":"/tmp/pulse","title":"Parent","timestamp":"1970-01-01T00:01:40Z","kind":"session.idle"}
    """.data(using: .utf8)!
    let childWorkingPayload = """
    {"agent":"codex","sessionID":"thread_child","projectPath":"/tmp/pulse","title":"Child","timestamp":"1970-01-01T00:01:41Z","kind":"session.working","parentSessionID":"thread_parent","isSubagent":true}
    """.data(using: .utf8)!
    let childIdlePayload = """
    {"agent":"codex","sessionID":"thread_child","projectPath":"/tmp/pulse","title":"Child","timestamp":"1970-01-01T00:01:42Z","kind":"session.idle","parentSessionID":"thread_parent","isSubagent":true}
    """.data(using: .utf8)!

    try server.handlePayload(parentPayload)
    try server.handlePayload(childWorkingPayload)
    try server.handlePayload(childIdlePayload)

    XCTAssertEqual(store.groups[0].slots.count, 1)
    XCTAssertEqual(store.groups[0].slots.first?.sessionID, "thread_parent")
    XCTAssertEqual(store.groups[0].slots.first?.state, .idle)
    XCTAssertEqual(store.groups[0].slots.first?.sessionState, .idle)
}
```

- [ ] **Step 4: Run the focused tests to verify they fail**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests -only-testing:pulseTests/PulseAgentStatusServerTests
```

Expected:

```text
Test suite 'AgentIntegrationManagerTests' started
Test suite 'PulseAgentStatusServerTests' started
... XCTAssertTrue failed ...
** TEST FAILED **
```

- [ ] **Step 5: Commit the failing-test checkpoint**

```bash
git add pulseTests/AgentIntegrationManagerTests.swift pulseTests/PulseAgentStatusServerTests.swift
git commit -m "test: add codex subagent aggregation regressions"
```

### Task 2: Normalize Codex Child Metadata In The Hook

**Files:**
- Modify: `pulse/Managers/CodexIntegrationInstaller.swift`
- Modify: `pulseTests/AgentIntegrationManagerTests.swift`
- Modify: `pulseTests/PulseAgentStatusServerTests.swift`

- [ ] **Step 1: Add Codex parent-session normalization in the generated hook**

Update the Node script inside `pulse/Managers/CodexIntegrationInstaller.swift` so it normalizes parent identifiers before deciding whether an event is a child session:

```swift
        function normalizeParentSessionID(parentSessionID) {
          if (typeof parentSessionID !== "string") {
            return "";
          }

          if (parentSessionID.startsWith("thread_") === false) {
            return "";
          }

          return parentSessionID;
        }

        const normalizedParentSessionID = normalizeParentSessionID(parentSessionID);
        const isSubagent = normalizedParentSessionID.length > 0 && eventName.startsWith("Subagent");
```

And update the emitted payload construction to use only the normalized value:

```swift
        const normalizedPayload = {
          agent: "codex",
          sessionID: sessionID || `codex-${Date.now()}`,
          projectPath,
          title: normalizedTitle,
          timestamp: new Date().toISOString(),
          kind,
          ...(normalizedParentSessionID.length > 0 ? { parentSessionID: normalizedParentSessionID } : {}),
          ...(isSubagent ? { isSubagent: true } : {}),
        };
```

- [ ] **Step 2: Keep Codex event kind mapping unchanged while preserving startup bypass**

Ensure the surrounding logic still includes:

```swift
        if (eventName === "SessionStart" && source === "startup") {
          process.stdout.write(JSON.stringify({ continue: true }) + "\\n");
          process.exit(0);
        }

        const kind = eventName === "Stop" || eventName === "SubagentStop" ? "session.idle" : "session.working";
```

This task changes child classification only, not the event-kind mapping.

- [ ] **Step 3: Re-run the focused tests to verify they pass**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentIntegrationManagerTests -only-testing:pulseTests/PulseAgentStatusServerTests
```

Expected:

```text
Test suite 'AgentIntegrationManagerTests' passed
Test suite 'PulseAgentStatusServerTests' passed
** TEST SUCCEEDED **
```

- [ ] **Step 4: Commit the implementation checkpoint**

```bash
git add pulse/Managers/CodexIntegrationInstaller.swift pulseTests/AgentIntegrationManagerTests.swift pulseTests/PulseAgentStatusServerTests.swift
git commit -m "fix: aggregate codex subagents into parent sessions"
```

### Task 3: Full Verification

**Files:**
- Modify: none

- [ ] **Step 1: Run the full macOS test suite**

Run:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
```

Expected:

```text
Testing started
Test session results, code coverage, and logs:
...
** TEST SUCCEEDED **
```

- [ ] **Step 2: Run a Debug build**

Run:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected:

```text
Build settings from command line
...
** BUILD SUCCEEDED **
```

- [ ] **Step 3: Manually verify Codex subagent visibility behavior**

Check:

```text
1. Start a Codex main session and trigger subagent work.
2. Confirm Pulse shows only the parent Codex session in the panel.
3. Confirm the parent stays working while the child is active.
4. Confirm child stop/idle returns the parent to its own base state.
5. Confirm child error does not create a standalone slot or turn the parent red.
```

- [ ] **Step 4: Commit the verification checkpoint**

```bash
git add .
git commit -m "test: verify codex subagent aggregation"
```
