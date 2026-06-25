import XCTest
@testable import Pulse

final class PulseAgentStatusServerTests: XCTestCase {
    @MainActor
    func testHandlePayloadForwardsValidEventToStore() throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let server = PulseAgentStatusServer(store: store)
        let payload = """
        {"agent":"opencode","sessionID":"s1","projectPath":"/tmp/pulse","title":"Task","timestamp":"1970-01-01T00:01:40Z","kind":"session.working"}
        """.data(using: .utf8)!

        try server.handlePayload(payload)

        XCTAssertEqual(store.groups[0].slots.first?.sessionID, "s1")
        XCTAssertEqual(store.groups[0].slots.first?.sessionTitle, "Task")
        XCTAssertEqual(store.groups[0].slots.first?.state, .working)
        XCTAssertEqual(store.groups[0].slots.first?.sessionState, .working)
    }

    @MainActor
    func testHandlePayloadRejectsMalformedEvent() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )
        let server = PulseAgentStatusServer(store: store)

        XCTAssertThrowsError(try server.handlePayload(Data("{}".utf8)))
        XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])
    }

    @MainActor
    func testHandlePayloadRejectsMissingIdentifiers() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let server = PulseAgentStatusServer(store: store)
        let payload = """
        {"agent":"opencode","sessionID":"","projectPath":"","title":"Task","timestamp":"1970-01-01T00:01:40Z","kind":"session.working"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try server.handlePayload(payload))
        XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])
    }

    @MainActor
    func testStartIsSafeToCallMoreThanOnce() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let server = PulseAgentStatusServer(store: store)

        XCTAssertNoThrow(server.start())
        XCTAssertNoThrow(server.start())
    }

    @MainActor
    func testFramedPayloadsHandleSplitPayload() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let server = PulseAgentStatusServer(store: store)
        var buffer = Data()
        let payload = """
        {"agent":"opencode","sessionID":"split","projectPath":"/tmp/split","title":"Split","timestamp":"1970-01-01T00:01:40Z","kind":"session.working"}
        """
        let midpoint = payload.index(payload.startIndex, offsetBy: payload.count / 2)

        server.handleFramedPayloads(Data(payload[..<midpoint].utf8), buffer: &buffer)
        XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])

        server.handleFramedPayloads(Data((payload[midpoint...] + "\n").utf8), buffer: &buffer)

        XCTAssertEqual(store.groups[0].slots.first?.sessionID, "split")
        XCTAssertEqual(store.groups[0].slots.first?.state, .working)
        XCTAssertTrue(buffer.isEmpty)
    }

    @MainActor
    func testFramedPayloadsHandleCoalescedPayloads() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )
        let server = PulseAgentStatusServer(store: store)
        var buffer = Data()
        let payloads = """
        {"agent":"codex","sessionID":"one","projectPath":"/tmp/one","title":"One","timestamp":"1970-01-01T00:01:40Z","kind":"session.working"}
        {"agent":"codex","sessionID":"two","projectPath":"/tmp/two","title":"Two","timestamp":"1970-01-01T00:01:41Z","kind":"session.idle"}

        """

        server.handleFramedPayloads(Data(payloads.utf8), buffer: &buffer)

        XCTAssertEqual(store.groups[0].slots.map(\.sessionID), ["one", "two"])
        XCTAssertEqual(store.groups[0].slots.map(\.state), [.working, .idle])
        XCTAssertTrue(buffer.isEmpty)
    }

    @MainActor
    func testHandlePayloadAggregatesSubagentIntoParentSession() throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let server = PulseAgentStatusServer(store: store)
        let parentPayload = """
        {"agent":"opencode","sessionID":"parent","projectPath":"/tmp/pulse","title":"Task","timestamp":"1970-01-01T00:01:40Z","kind":"session.idle"}
        """.data(using: .utf8)!
        let childPayload = """
        {"agent":"opencode","sessionID":"child","projectPath":"/tmp/pulse","title":"Child","timestamp":"1970-01-01T00:01:41Z","kind":"session.working","parentSessionID":"parent","isSubagent":true}
        """.data(using: .utf8)!

        try server.handlePayload(parentPayload)
        try server.handlePayload(childPayload)

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots.first?.sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots.first?.state, .working)
        XCTAssertEqual(store.groups[0].slots.first?.sessionState, .idle)
    }

    @MainActor
    func testHandlePayloadAggregatesCodexSubagentThreadIntoParentSession() throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )
        let server = PulseAgentStatusServer(store: store)
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        try harness.runHook(with: """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_parent-2026-06-24.jsonl","session_id":"thread_parent","thread_id":"thread_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!)
        try server.handlePayload(try normalizedPayloadData(from: harness.capturedSenderPayload(), timestamp: "1970-01-01T00:01:40Z"))

        try harness.runHook(with: """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_child-2026-06-24.jsonl","session_id":"thread_child","thread_id":"thread_child","thread_source":"subagent","parent_thread_id":"thread_parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"thread_parent"}}},"cwd":"/tmp/pulse"}
        """.data(using: .utf8)!)
        try server.handlePayload(try normalizedPayloadData(from: harness.capturedSenderPayload(), timestamp: "1970-01-01T00:01:41Z"))

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots.first?.sessionID, "thread_parent")
        XCTAssertEqual(store.groups[0].slots.first?.state, .working)
        XCTAssertEqual(store.groups[0].slots.first?.sessionState, .working)
    }

    @MainActor
    func testHandlePayloadLetsCodexParentReturnToBaseStateAfterChildStops() throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )
        let server = PulseAgentStatusServer(store: store)
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        try harness.runHook(with: """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_parent-2026-06-24.jsonl","session_id":"thread_parent","thread_id":"thread_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!)
        try server.handlePayload(try normalizedPayloadData(from: harness.capturedSenderPayload(), timestamp: "1970-01-01T00:01:40Z"))

        try harness.runHook(with: """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_child-2026-06-24.jsonl","session_id":"thread_child","thread_id":"thread_child","thread_source":"subagent","parent_thread_id":"thread_parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"thread_parent"}}},"cwd":"/tmp/pulse"}
        """.data(using: .utf8)!)
        try server.handlePayload(try normalizedPayloadData(from: harness.capturedSenderPayload(), timestamp: "1970-01-01T00:01:41Z"))

        try harness.runHook(with: """
        {"hook_event_name":"Stop","transcript_path":"/Users/zyao/.codex/sessions/thread_child-2026-06-24.jsonl","session_id":"thread_child","thread_id":"thread_child","thread_source":"subagent","parent_thread_id":"thread_parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"thread_parent"}}},"cwd":"/tmp/pulse"}
        """.data(using: .utf8)!)
        try server.handlePayload(try normalizedPayloadData(from: harness.capturedSenderPayload(), timestamp: "1970-01-01T00:01:42Z"))

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots.first?.sessionID, "thread_parent")
        XCTAssertEqual(store.groups[0].slots.first?.state, .working)
        XCTAssertEqual(store.groups[0].slots.first?.sessionState, .working)
    }

    private func normalizedPayloadData(from payload: [String: Any], timestamp: String) throws -> Data {
        var copy = payload
        copy["timestamp"] = timestamp
        return try JSONSerialization.data(withJSONObject: copy, options: [])
    }
}
