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

final class UserDefaultsAgentStatusPersistence: AgentStatusPersistence {
    private let defaults: UserDefaults
    private let key = "agentStatusStore"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedAgentStatusStore? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(PersistedAgentStatusStore.self, from: data)
    }

    func save(_ store: PersistedAgentStatusStore) {
        guard let data = try? JSONEncoder().encode(store) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}

@MainActor
final class AgentStatusStore: ObservableObject {
    private struct SessionEventVersion {
        let timestamp: Date
        let precedence: Int
    }

    @Published private(set) var groups: [AgentStatusGroup]

    private let persistence: AgentStatusPersistence
    private let visibleSlotCap = 4
    private let autoClearInterval: TimeInterval = 60
    private let idleThreshold: TimeInterval = 300
    private var autoClearTimer: Timer?
    private var workingSubagentSessionIDsByParent: [AgentStatusAgent: [String: Set<String>]] = [:]
    private var latestEventVersionsBySessionID: [AgentStatusAgent: [String: SessionEventVersion]] = [:]

    convenience init(enabledAgents: [AgentStatusAgent]) {
        self.init(
            persistence: UserDefaultsAgentStatusPersistence(),
            enabledAgents: enabledAgents
        )
    }

    init(persistence: AgentStatusPersistence, enabledAgents: [AgentStatusAgent]) {
        self.persistence = persistence
        groups = Self.bootstrapGroups(from: persistence.load(), enabledAgents: enabledAgents)
        latestEventVersionsBySessionID = Self.bootstrapLatestEventVersions(from: groups)
    }

    func apply(_ event: PulseAgentStatusEvent) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == event.agent }) else {
            return
        }

        guard shouldApply(event) else {
            return
        }

        rememberLatestVersion(for: event)

        if event.isSubagent, let parentSessionID = event.parentSessionID, parentSessionID.isEmpty == false {
            applySubagentEvent(event, parentSessionID: parentSessionID, in: groupIndex)
        } else {
            applyPrimarySessionEvent(event, in: groupIndex)
        }

        updateOverflowCount(for: groupIndex)
        persist()
    }

    func deleteSlot(agent: AgentStatusAgent, slotID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else {
            return
        }

        if let sessionID = groups[groupIndex].slots.first(where: { $0.id == slotID })?.sessionID {
            workingSubagentSessionIDsByParent[agent]?[sessionID] = nil
        }
        groups[groupIndex].slots.removeAll { $0.id == slotID }

        if groups[groupIndex].slots.isEmpty {
            groups[groupIndex].slots = [Self.placeholder(for: agent)]
        }

        updateOverflowCount(for: groupIndex)
        persist()
    }

    func clearIdleSlots(for agent: AgentStatusAgent) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else {
            return
        }

        groups[groupIndex].slots.removeAll { $0.state == .idle }

        if groups[groupIndex].slots.isEmpty {
            groups[groupIndex].slots = [Self.placeholder(for: agent)]
        }

        updateOverflowCount(for: groupIndex)
        persist()
    }

    func clearAllSlots(for agent: AgentStatusAgent) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else {
            return
        }

        workingSubagentSessionIDsByParent[agent] = [:]
        groups[groupIndex].slots = [Self.placeholder(for: agent)]
        updateOverflowCount(for: groupIndex)
        persist()
    }

    func clearIdleSlotsOlderThan(_ threshold: TimeInterval, for agent: AgentStatusAgent) {
        guard let groupIndex = groups.firstIndex(where: { $0.agent == agent }) else { return }

        let now = Date()
        groups[groupIndex].slots.removeAll { slot in
            guard slot.state == .idle, let lastSeen = slot.lastSeenAt else { return false }
            return now.timeIntervalSince(lastSeen) >= threshold
        }

        if groups[groupIndex].slots.isEmpty {
            groups[groupIndex].slots = [Self.placeholder(for: agent)]
        }

        updateOverflowCount(for: groupIndex)
        persist()
    }

    func startAutoClear() {
        stopAutoClear()
        autoClearTimer = Timer.scheduledTimer(withTimeInterval: autoClearInterval, repeats: true) { [weak self] _ in
            self?.performAutoClear()
        }
    }

    func stopAutoClear() {
        autoClearTimer?.invalidate()
        autoClearTimer = nil
    }

    private func performAutoClear() {
        for group in groups {
            clearIdleSlotsOlderThan(idleThreshold, for: group.agent)
        }
    }

    func visibleGroups(enabledAgents: Set<AgentStatusAgent>, featureEnabled: Bool) -> [AgentStatusGroup] {
        guard featureEnabled else {
            return []
        }

        return groups.filter { enabledAgents.contains($0.agent) }
    }

    private func applyPrimarySessionEvent(_ event: PulseAgentStatusEvent, in groupIndex: Int) {
        if let slotIndex = groups[groupIndex].slots.firstIndex(where: { $0.sessionID == event.sessionID }) {
            updatePrimarySlot(at: slotIndex, in: groupIndex, with: event)
            return
        }

        if let placeholderIndex = groups[groupIndex].slots.firstIndex(where: \.isPlaceholder) {
            updatePrimarySlot(at: placeholderIndex, in: groupIndex, with: event)
            return
        }

        groups[groupIndex].slots.append(makePrimarySlot(from: event))
    }

    private func applySubagentEvent(_ event: PulseAgentStatusEvent, parentSessionID: String, in groupIndex: Int) {
        removeStandaloneSubagentSlotIfNeeded(sessionID: event.sessionID, parentSessionID: parentSessionID, in: groupIndex)
        updateWorkingSubagentState(for: event, parentSessionID: parentSessionID)

        guard let slotIndex = groups[groupIndex].slots.firstIndex(where: { $0.sessionID == parentSessionID }) else {
            return
        }

        let previousState = groups[groupIndex].slots[slotIndex].state
        let baseState = groups[groupIndex].slots[slotIndex].sessionState ?? groups[groupIndex].slots[slotIndex].state
        groups[groupIndex].slots[slotIndex].state = effectiveState(
            for: event.agent,
            sessionID: parentSessionID,
            baseState: baseState
        )
        groups[groupIndex].slots[slotIndex].lastSeenAt = event.timestamp
        if groups[groupIndex].slots[slotIndex].state != previousState {
            groups[groupIndex].slots[slotIndex].lastTransitionAt = event.timestamp
        }
    }

    private func removeStandaloneSubagentSlotIfNeeded(
        sessionID: String,
        parentSessionID: String,
        in groupIndex: Int
    ) {
        guard sessionID != parentSessionID,
              let slotIndex = groups[groupIndex].slots.firstIndex(where: { $0.sessionID == sessionID }) else {
            return
        }

        groups[groupIndex].slots.remove(at: slotIndex)

        if groups[groupIndex].slots.isEmpty {
            groups[groupIndex].slots = [Self.placeholder(for: groups[groupIndex].agent)]
        }
    }

    private func updatePrimarySlot(at slotIndex: Int, in groupIndex: Int, with event: PulseAgentStatusEvent) {
        let existingID = groups[groupIndex].slots[slotIndex].id
        groups[groupIndex].slots[slotIndex] = makePrimarySlot(from: event, existingID: existingID)
    }

    private func makePrimarySlot(from event: PulseAgentStatusEvent, existingID: UUID = UUID()) -> AgentSessionSlot {
        let sessionState = Self.map(event.kind)
        return AgentSessionSlot(
            id: existingID,
            agent: event.agent,
            sessionID: event.sessionID,
            projectPath: event.projectPath,
            projectName: URL(fileURLWithPath: event.projectPath).lastPathComponent,
            sessionTitle: event.sessionTitle,
            state: effectiveState(for: event.agent, sessionID: event.sessionID, baseState: sessionState),
            sessionState: sessionState,
            lastTransitionAt: event.timestamp,
            lastSeenAt: event.timestamp
        )
    }

    private func updateWorkingSubagentState(for event: PulseAgentStatusEvent, parentSessionID: String) {
        var sessionsByParent = workingSubagentSessionIDsByParent[event.agent] ?? [:]
        var childSessionIDs = sessionsByParent[parentSessionID] ?? []

        switch event.kind {
        case .sessionStarted, .sessionWorking:
            childSessionIDs.insert(event.sessionID)
        case .sessionIdle, .sessionError, .sessionClosed:
            childSessionIDs.remove(event.sessionID)
        }

        if childSessionIDs.isEmpty {
            sessionsByParent[parentSessionID] = nil
        } else {
            sessionsByParent[parentSessionID] = childSessionIDs
        }
        workingSubagentSessionIDsByParent[event.agent] = sessionsByParent
    }

    private func effectiveState(
        for agent: AgentStatusAgent,
        sessionID: String,
        baseState: AgentSessionLightState
    ) -> AgentSessionLightState {
        if let childSessionIDs = workingSubagentSessionIDsByParent[agent]?[sessionID],
           childSessionIDs.isEmpty == false {
            return .working
        }

        return baseState
    }

    private func shouldApply(_ event: PulseAgentStatusEvent) -> Bool {
        let version = Self.version(for: event)
        guard let existingVersion = latestEventVersionsBySessionID[event.agent]?[event.sessionID] else {
            return true
        }

        if version.timestamp != existingVersion.timestamp {
            return version.timestamp > existingVersion.timestamp
        }

        return version.precedence >= existingVersion.precedence
    }

    private func rememberLatestVersion(for event: PulseAgentStatusEvent) {
        var versionsBySessionID = latestEventVersionsBySessionID[event.agent] ?? [:]
        versionsBySessionID[event.sessionID] = Self.version(for: event)
        latestEventVersionsBySessionID[event.agent] = versionsBySessionID
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
            let slots = restoredSlots.isEmpty ? [placeholder(for: agent)] : restoredSlots.map { slot in
                var normalized = slot
                if normalized.isPlaceholder == false, normalized.sessionState == nil {
                    normalized.sessionState = normalized.state
                }
                return normalized
            }
            let overflowCount = max(0, slots.count - 4)
            return AgentStatusGroup(agent: agent, slots: slots, overflowCount: overflowCount)
        }
    }

    private static func bootstrapLatestEventVersions(
        from groups: [AgentStatusGroup]
    ) -> [AgentStatusAgent: [String: SessionEventVersion]] {
        var versionsByAgent: [AgentStatusAgent: [String: SessionEventVersion]] = [:]

        for group in groups {
            var versionsBySessionID: [String: SessionEventVersion] = [:]

            for slot in group.slots {
                guard let sessionID = slot.sessionID,
                      let timestamp = slot.lastSeenAt ?? slot.lastTransitionAt else {
                    continue
                }

                let state = slot.sessionState ?? slot.state
                versionsBySessionID[sessionID] = SessionEventVersion(
                    timestamp: timestamp,
                    precedence: precedence(for: state)
                )
            }

            versionsByAgent[group.agent] = versionsBySessionID
        }

        return versionsByAgent
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
            sessionState: nil,
            lastTransitionAt: nil,
            lastSeenAt: nil
        )
    }

    private static func map(_ kind: PulseAgentStatusEventKind) -> AgentSessionLightState {
        switch kind {
        case .sessionWorking:
            return .working
        case .sessionStarted:
            return .idle
        case .sessionIdle, .sessionClosed:
            return .idle
        case .sessionError:
            return .error
        }
    }

    private static func version(for event: PulseAgentStatusEvent) -> SessionEventVersion {
        SessionEventVersion(
            timestamp: event.timestamp,
            precedence: precedence(for: map(event.kind))
        )
    }

    private static func precedence(for state: AgentSessionLightState) -> Int {
        switch state {
        case .working, .empty:
            return 0
        case .idle:
            return 1
        case .error:
            return 2
        }
    }
}
