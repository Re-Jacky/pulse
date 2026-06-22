import Foundation
import XCTest
@testable import Pulse

final class AgentStatusStoreTests: XCTestCase {
    func testPulseAgentStatusEventUsesSessionTitleInCodableRoundTrip() throws {
        let event = PulseAgentStatusEvent(
            agent: .codex,
            sessionID: "session-1",
            projectPath: "/tmp/project",
            sessionTitle: "Fix menu bar",
            timestamp: Date(timeIntervalSince1970: 123),
            kind: .sessionWorking,
            message: "running"
        )

        let data = try JSONEncoder().encode(event)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObject["sessionTitle"] as? String, "Fix menu bar")
        XCTAssertNil(jsonObject["title"])

        let decoded = try JSONDecoder().decode(PulseAgentStatusEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testPersistedAgentStatusStoreRoundTripsThroughJSON() throws {
        let store = PersistedAgentStatusStore(
            groups: [
                PersistedAgentStatusGroup(
                    agent: .openCode,
                    slots: [
                        AgentSessionSlot(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                            agent: .openCode,
                            sessionID: "session-42",
                            projectPath: "/tmp/pulse",
                            projectName: "pulse",
                            sessionTitle: "Implement lights",
                            state: .working,
                            lastTransitionAt: Date(timeIntervalSince1970: 200),
                            lastSeenAt: Date(timeIntervalSince1970: 250)
                        )
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(PersistedAgentStatusStore.self, from: data)

        XCTAssertEqual(decoded, store)
    }
}
