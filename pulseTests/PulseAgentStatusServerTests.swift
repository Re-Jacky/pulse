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
}
