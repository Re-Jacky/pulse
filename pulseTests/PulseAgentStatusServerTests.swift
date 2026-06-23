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
}
