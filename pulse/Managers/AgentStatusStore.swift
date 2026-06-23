import Combine
import Foundation

protocol AgentStatusPersistence {
    func load() -> PersistedAgentStatusStore?
    func save(_ store: PersistedAgentStatusStore)
}

final class InMemoryAgentStatusPersistence: AgentStatusPersistence {
    private var stored: PersistedAgentStatusStore?

    func load() -> PersistedAgentStatusStore? {
        stored
    }

    func save(_ store: PersistedAgentStatusStore) {
        stored = store
    }
}

@MainActor
final class AgentStatusStore: ObservableObject {
    @Published private(set) var groups: [AgentStatusGroup]

    private let persistence: AgentStatusPersistence
    private let visibleSlotCap = 4

    init(persistence: AgentStatusPersistence, enabledAgents: [AgentStatusAgent]) {
        self.persistence = persistence
        groups = Self.bootstrapGroups(from: persistence.load(), enabledAgents: enabledAgents)
    }

    func apply(_ event: PulseAgentStatusEvent) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == event.agent }) else {
            return
        }

        if let slotIndex = groups[groupIndex].slots.firstIndex(where: { $0.sessionID == event.sessionID }) {
            updateSlot(at: slotIndex, in: groupIndex, with: event)
        } else if let placeholderIndex = groups[groupIndex].slots.firstIndex(where: \.isPlaceholder) {
            updateSlot(at: placeholderIndex, in: groupIndex, with: event)
        } else {
            groups[groupIndex].slots.append(makeSlot(from: event))
        }

        updateOverflowCount(for: groupIndex)
        persist()
    }

    func deleteSlot(agent: AgentStatusAgent, slotID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else {
            return
        }

        groups[groupIndex].slots.removeAll { $0.id == slotID }

        if groups[groupIndex].slots.isEmpty {
            groups[groupIndex].slots = [Self.placeholder(for: agent)]
        }

        updateOverflowCount(for: groupIndex)
        persist()
    }

    private func updateSlot(at slotIndex: Int, in groupIndex: Int, with event: PulseAgentStatusEvent) {
        let existingID = groups[groupIndex].slots[slotIndex].id
        groups[groupIndex].slots[slotIndex] = makeSlot(from: event, existingID: existingID)
    }

    private func makeSlot(from event: PulseAgentStatusEvent, existingID: UUID = UUID()) -> AgentSessionSlot {
        AgentSessionSlot(
            id: existingID,
            agent: event.agent,
            sessionID: event.sessionID,
            projectPath: event.projectPath,
            projectName: URL(fileURLWithPath: event.projectPath).lastPathComponent,
            sessionTitle: event.sessionTitle,
            state: Self.map(event.kind),
            lastTransitionAt: event.timestamp,
            lastSeenAt: event.timestamp
        )
    }

    private func persist() {
        var mergedGroups = persistence.load()?.groups ?? []
        for group in groups {
            let persistedGroup = PersistedAgentStatusGroup(agent: group.agent, slots: group.slots)
            if let index = mergedGroups.firstIndex(where: { $0.agent == group.agent }) {
                mergedGroups[index] = persistedGroup
            } else {
                mergedGroups.append(persistedGroup)
            }
        }

        persistence.save(
            PersistedAgentStatusStore(
                groups: mergedGroups
            )
        )
    }

    private func updateOverflowCount(for groupIndex: Int) {
        groups[groupIndex].overflowCount = max(0, groups[groupIndex].slots.count - visibleSlotCap)
    }

    private static func bootstrapGroups(
        from persisted: PersistedAgentStatusStore?,
        enabledAgents: [AgentStatusAgent]
    ) -> [AgentStatusGroup] {
        enabledAgents.map { agent in
            let restoredSlots = persisted?.groups.first(where: { $0.agent == agent })?.slots ?? []
            let slots = restoredSlots.isEmpty ? [placeholder(for: agent)] : restoredSlots
            let overflowCount = max(0, slots.count - 4)
            return AgentStatusGroup(agent: agent, slots: slots, overflowCount: overflowCount)
        }
    }

    private static func placeholder(for agent: AgentStatusAgent) -> AgentSessionSlot {
        AgentSessionSlot(
            id: UUID(),
            agent: agent,
            sessionID: nil,
            projectPath: nil,
            projectName: nil,
            sessionTitle: nil,
            state: .empty,
            lastTransitionAt: nil,
            lastSeenAt: nil
        )
    }

    private static func map(_ kind: PulseAgentStatusEventKind) -> AgentSessionLightState {
        switch kind {
        case .sessionStarted, .sessionWorking:
            return .working
        case .sessionIdle, .sessionClosed:
            return .idle
        case .sessionError:
            return .error
        }
    }
}
