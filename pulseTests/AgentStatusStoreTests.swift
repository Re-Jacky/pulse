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

    @MainActor
    func testInitialStateCreatesOnePlaceholderPerEnabledAgent() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode, .codex]
        )

        XCTAssertEqual(store.groups.count, 2)
        XCTAssertEqual(
            store.groups.first(where: { $0.agent == .openCode })?.slots.map(\.state),
            [.empty]
        )
        XCTAssertEqual(
            store.groups.first(where: { $0.agent == .codex })?.slots.map(\.state),
            [.empty]
        )
    }

    @MainActor
    func testInitialStateDoesNotPersistBootstrappedGroups() {
        let persistence = SpyAgentStatusPersistence()

        _ = AgentStatusStore(
            persistence: persistence,
            enabledAgents: [.openCode]
        )

        XCTAssertEqual(persistence.saveCallCount, 0)
    }

    @MainActor
    func testNewSessionReusesFirstPlaceholderSlot() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Fix menu bar",
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .sessionWorking,
                message: nil
            )
        )

        let slots = store.groups[0].slots
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].state, .working)
        XCTAssertEqual(slots[0].sessionID, "session-1")
        XCTAssertEqual(slots[0].projectName, "pulse")
        XCTAssertEqual(slots[0].sessionTitle, "Fix menu bar")
    }

    @MainActor
    func testPersistPreservesGroupsForAgentsThatAreNotCurrentlyEnabled() {
        let persistence = SpyAgentStatusPersistence(
            persisted: PersistedAgentStatusStore(
                groups: [
                    PersistedAgentStatusGroup(
                        agent: .codex,
                        slots: [
                            AgentSessionSlot(
                                id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                agent: .codex,
                                sessionID: "codex-session",
                                projectPath: "/tmp/codex",
                                projectName: "codex",
                                sessionTitle: "Idle Codex",
                                state: .idle,
                                lastTransitionAt: Date(timeIntervalSince1970: 300),
                                lastSeenAt: Date(timeIntervalSince1970: 300)
                            )
                        ]
                    )
                ]
            )
        )
        let store = AgentStatusStore(
            persistence: persistence,
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "opencode-session",
                projectPath: "/tmp/opencode",
                sessionTitle: "Working OpenCode",
                timestamp: Date(timeIntervalSince1970: 400),
                kind: .sessionWorking,
                message: nil
            )
        )

        XCTAssertEqual(
            persistence.savedStore?.groups.map(\.agent),
            [.codex, .openCode]
        )
        XCTAssertEqual(
            persistence.savedStore?.groups.first(where: { $0.agent == .codex })?.slots.first?.sessionID,
            "codex-session"
        )
    }


    @MainActor
    func testIdleAndErrorSessionsStayVisibleUntilDeleted() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "a",
                projectPath: "/tmp/a",
                sessionTitle: "A",
                timestamp: Date(timeIntervalSince1970: 10),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "b",
                projectPath: "/tmp/b",
                sessionTitle: "B",
                timestamp: Date(timeIntervalSince1970: 11),
                kind: .sessionError,
                message: "failed"
            )
        )

        XCTAssertEqual(store.groups[0].slots.map(\.state), [.idle, .error])

        store.deleteSlot(agent: .codex, slotID: store.groups[0].slots[0].id)

        XCTAssertEqual(store.groups[0].slots.map(\.state), [.error])
    }
}

private final class SpyAgentStatusPersistence: AgentStatusPersistence {
    private let persisted: PersistedAgentStatusStore?
    private(set) var saveCallCount = 0
    private(set) var savedStore: PersistedAgentStatusStore?

    init(persisted: PersistedAgentStatusStore? = nil) {
        self.persisted = persisted
    }

    func load() -> PersistedAgentStatusStore? {
        savedStore ?? persisted
    }

    func save(_ store: PersistedAgentStatusStore) {
        saveCallCount += 1
        savedStore = store
    }
}
