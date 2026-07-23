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
            message: "running",
            parentSessionID: "parent-1",
            isSubagent: true,
            transcriptPath: "/tmp/session.jsonl",
            turnID: "turn-1"
        )

        let data = try JSONEncoder().encode(event)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObject["sessionTitle"] as? String, "Fix menu bar")
        XCTAssertNil(jsonObject["title"])
        XCTAssertEqual(jsonObject["transcriptPath"] as? String, "/tmp/session.jsonl")
        XCTAssertEqual(jsonObject["turnID"] as? String, "turn-1")

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
                            sessionState: .working,
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
    func testSessionStartCreatesIdleSlotUntilWorkBegins() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "New Codex Window",
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .sessionStarted,
                message: nil
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "New Codex Window",
                timestamp: Date(timeIntervalSince1970: 101),
                kind: .sessionWorking,
                message: nil
            )
        )

        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .working)
    }

    @MainActor
    func testUnmaterializedCodexSessionStartIsRemovedAfterValidation() async throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex],
            codexSessionMaterializationDelay: 0,
            codexSessionExists: { _ in false }
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "ephemeral",
                projectPath: "/tmp/pulse",
                sessionTitle: "Ephemeral",
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .sessionStarted,
                message: nil
            )
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].state, .empty)
        XCTAssertNil(store.groups[0].slots[0].sessionID)
    }

    @MainActor
    func testCodexMaterializationCleanupDoesNotRemoveNewerWorkingEvent() async throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex],
            codexSessionMaterializationDelay: 0,
            codexSessionExists: { _ in false }
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Started",
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .sessionStarted,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Working",
                timestamp: Date(timeIntervalSince1970: 101),
                kind: .sessionWorking,
                message: nil
            )
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "session-1")
        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .working)
    }

    @MainActor
    func testCodexAbortedTranscriptTurnMarksWorkingSessionIdle() async throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex],
            codexTurnAbortedCheckDelay: 0,
            codexTurnWasAborted: { transcriptPath, turnID in
                transcriptPath == "/tmp/session.jsonl" && turnID == "turn-1"
            }
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Working",
                timestamp: Date(timeIntervalSince1970: 150),
                kind: .sessionWorking,
                message: nil,
                transcriptPath: "/tmp/session.jsonl",
                turnID: "turn-1"
            )
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "session-1")
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testCodexWorkingSessionStaysWorkingWhenTranscriptTurnIsNotAborted() async throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex],
            codexTurnAbortedCheckDelay: 0,
            codexTurnWasAborted: { _, _ in false }
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Working",
                timestamp: Date(timeIntervalSince1970: 160),
                kind: .sessionWorking,
                message: nil,
                transcriptPath: "/tmp/session.jsonl",
                turnID: "turn-1"
            )
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "session-1")
        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .working)
    }

    @MainActor
    func testUnmaterializedCodexSubagentStartDoesNotLeaveParentWorking() async throws {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex],
            codexSessionMaterializationDelay: 0,
            codexSessionExists: { _ in false }
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Parent",
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "child",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child",
                timestamp: Date(timeIntervalSince1970: 101),
                kind: .sessionStarted,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )

        XCTAssertEqual(store.groups[0].slots[0].state, .working)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
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
                                sessionState: .idle,
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

    @MainActor
    func testSubagentWorkingKeepsParentVisibleAsWorkingWithoutAddingChildSlot() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "child-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 101),
                kind: .sessionWorking,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testParentFallsBackToOwnIdleStateWhenLastWorkingSubagentStops() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 200),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "child-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 201),
                kind: .sessionWorking,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "child-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 202),
                kind: .sessionIdle,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testPrimaryCloseClearsWorkingSubagentsAndShowsIdle() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 250),
                kind: .sessionWorking,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "child-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 251),
                kind: .sessionWorking,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 252),
                kind: .sessionClosed,
                message: nil
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testSubagentErrorDoesNotChangeParentToError() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 300),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "child-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 301),
                kind: .sessionError,
                message: "boom",
                parentSessionID: "parent",
                isSubagent: true
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testParentInheritsExistingSubagentWorkWhenPrimaryEventArrivesLater() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "child-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 400),
                kind: .sessionWorking,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 401),
                kind: .sessionIdle,
                message: nil
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testReclassifiedSubagentRemovesExistingStandaloneChildSlot() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "parent",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 425),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "child",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 426),
                kind: .sessionWorking,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .codex,
                sessionID: "child",
                projectPath: "/tmp/pulse",
                sessionTitle: "Child Session",
                timestamp: Date(timeIntervalSince1970: 427),
                kind: .sessionWorking,
                message: nil,
                parentSessionID: "parent",
                isSubagent: true
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "parent")
        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
    }

    @MainActor
    func testMessageParentIDsDoNotCreateSubagentAggregation() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 450),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 451),
                kind: .sessionWorking,
                message: nil,
                parentSessionID: "msg_parent",
                isSubagent: false
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].sessionID, "session-1")
        XCTAssertEqual(store.groups[0].slots[0].state, .working)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .working)
    }

    @MainActor
    func testOlderPrimaryWorkingEventDoesNotOverrideNewerIdleState() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 500),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: Date(timeIntervalSince1970: 499),
                kind: .sessionWorking,
                message: nil
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
        XCTAssertEqual(store.groups[0].slots[0].lastSeenAt, Date(timeIntervalSince1970: 500))
    }

    @MainActor
    func testEqualTimestampIdleWinsOverWorkingForPrimarySession() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )
        let timestamp = Date(timeIntervalSince1970: 600)

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: timestamp,
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "session-1",
                projectPath: "/tmp/pulse",
                sessionTitle: "Main Session",
                timestamp: timestamp,
                kind: .sessionWorking,
                message: nil
            )
        )

        XCTAssertEqual(store.groups[0].slots.count, 1)
        XCTAssertEqual(store.groups[0].slots[0].state, .idle)
        XCTAssertEqual(store.groups[0].slots[0].sessionState, .idle)
        XCTAssertEqual(store.groups[0].slots[0].lastSeenAt, timestamp)
    }

    @MainActor
    func testClearIdleSlotsLeavesOnePlaceholder() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.openCode]
        )

        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "idle-1",
                projectPath: "/tmp/p1",
                sessionTitle: "P1",
                timestamp: Date(timeIntervalSince1970: 500),
                kind: .sessionIdle,
                message: nil
            )
        )
        store.apply(
            PulseAgentStatusEvent(
                agent: .openCode,
                sessionID: "idle-2",
                projectPath: "/tmp/p2",
                sessionTitle: "P2",
                timestamp: Date(timeIntervalSince1970: 501),
                kind: .sessionIdle,
                message: nil
            )
        )

        store.clearIdleSlots(for: .openCode)

        XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])
    }

    @MainActor
    func testClearIdleSlotsPreservesWorkingAndErrorSlotsAndRecalculatesOverflow() {
        let persistence = SpyAgentStatusPersistence(
            persisted: PersistedAgentStatusStore(
                groups: [
                    PersistedAgentStatusGroup(
                        agent: .codex,
                        slots: [
                            AgentSessionSlot(
                                id: UUID(uuidString: "DDDDDDDD-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                agent: .codex,
                                sessionID: "disabled-codex",
                                projectPath: "/tmp/codex",
                                projectName: "codex",
                                sessionTitle: "Hidden Codex",
                                state: .idle,
                                sessionState: .idle,
                                lastTransitionAt: Date(timeIntervalSince1970: 450),
                                lastSeenAt: Date(timeIntervalSince1970: 450)
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

        let eventKinds: [PulseAgentStatusEventKind] = [
            .sessionWorking,
            .sessionIdle,
            .sessionError,
            .sessionIdle,
            .sessionWorking,
            .sessionError
        ]
        for (index, kind) in eventKinds.enumerated() {
            store.apply(
                PulseAgentStatusEvent(
                    agent: .openCode,
                    sessionID: "session-\(index)",
                    projectPath: "/tmp/session-\(index)",
                    sessionTitle: "Session \(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(900 + index)),
                    kind: kind,
                    message: nil
                )
            )
        }

        store.clearIdleSlots(for: .openCode)

        XCTAssertEqual(store.groups[0].slots.map(\.state), [.working, .error, .working, .error])
        XCTAssertEqual(store.groups[0].overflowCount, 0)
        XCTAssertEqual(
            persistence.savedStore?.groups.first(where: { $0.agent == .codex })?.slots.first?.sessionID,
            "disabled-codex"
        )
    }

    @MainActor
    func testClearAllSlotsLeavesOnePlaceholderAndResetsOverflow() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )

        for index in 0..<5 {
            store.apply(
                PulseAgentStatusEvent(
                    agent: .codex,
                    sessionID: "session-\(index)",
                    projectPath: "/tmp/\(index)",
                    sessionTitle: "T\(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(600 + index)),
                    kind: .sessionWorking,
                    message: nil
                )
            )
        }

        store.clearAllSlots(for: .codex)

        XCTAssertEqual(store.groups[0].slots.map(\.state), [.empty])
        XCTAssertEqual(store.groups[0].overflowCount, 0)
    }

    @MainActor
    func testOverflowCountTracksSlotsBeyondVisibleCap() {
        let store = AgentStatusStore(
            persistence: InMemoryAgentStatusPersistence(),
            enabledAgents: [.codex]
        )

        for index in 0..<5 {
            store.apply(
                PulseAgentStatusEvent(
                    agent: .codex,
                    sessionID: "session-\(index)",
                    projectPath: "/tmp/\(index)",
                    sessionTitle: "T\(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(700 + index)),
                    kind: .sessionWorking,
                    message: nil
                )
            )
        }

        XCTAssertEqual(store.groups[0].slots.count, 5)
        XCTAssertEqual(store.groups[0].overflowCount, 1)
    }

    func testUserDefaultsPersistenceRoundTripsSavedStore() {
        let suiteName = "AgentStatusStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = UserDefaultsAgentStatusPersistence(defaults: defaults)
        let expected = PersistedAgentStatusStore(
            groups: [
                PersistedAgentStatusGroup(
                    agent: .openCode,
                    slots: [
                        AgentSessionSlot(
                            id: UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                            agent: .openCode,
                            sessionID: "session-userdefaults",
                            projectPath: "/tmp/userdefaults",
                            projectName: "userdefaults",
                            sessionTitle: "Persist me",
                            state: .working,
                            sessionState: .working,
                            lastTransitionAt: Date(timeIntervalSince1970: 800),
                            lastSeenAt: Date(timeIntervalSince1970: 801)
                        )
                    ]
                )
            ]
        )

        persistence.save(expected)

        XCTAssertEqual(persistence.load(), expected)
        defaults.removePersistentDomain(forName: suiteName)
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
