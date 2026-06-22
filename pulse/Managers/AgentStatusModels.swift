import Foundation

enum AgentStatusAgent: String, CaseIterable, Codable, Hashable, Identifiable {
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openCode:
            return "OpenCode"
        case .codex:
            return "Codex"
        }
    }
}

enum AgentSessionLightState: String, Codable, Hashable {
    case empty
    case working
    case idle
    case error
}

enum PulseAgentStatusEventKind: String, Codable {
    case sessionStarted = "session.started"
    case sessionWorking = "session.working"
    case sessionIdle = "session.idle"
    case sessionError = "session.error"
    case sessionClosed = "session.closed"
}

struct PulseAgentStatusEvent: Codable, Equatable {
    let agent: AgentStatusAgent
    let sessionID: String
    let projectPath: String
    let sessionTitle: String
    let timestamp: Date
    let kind: PulseAgentStatusEventKind
    let message: String?
}

struct AgentSessionSlot: Identifiable, Codable, Equatable {
    let id: UUID
    let agent: AgentStatusAgent
    var sessionID: String?
    var projectPath: String?
    var projectName: String?
    var sessionTitle: String?
    var state: AgentSessionLightState
    var lastTransitionAt: Date?
    var lastSeenAt: Date?

    var isPlaceholder: Bool {
        state == .empty && sessionID == nil
    }
}

struct AgentStatusGroup: Identifiable, Equatable {
    let agent: AgentStatusAgent
    var slots: [AgentSessionSlot]
    var overflowCount: Int

    var id: String { agent.rawValue }
}

struct PersistedAgentStatusStore: Codable, Equatable {
    var groups: [PersistedAgentStatusGroup]
}

struct PersistedAgentStatusGroup: Codable, Equatable {
    let agent: AgentStatusAgent
    var slots: [AgentSessionSlot]
}
