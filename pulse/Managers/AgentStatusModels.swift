import Foundation
import Observation

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
    let parentSessionID: String?
    let isSubagent: Bool
    let transcriptPath: String?
    let turnID: String?

    init(
        agent: AgentStatusAgent,
        sessionID: String,
        projectPath: String,
        sessionTitle: String,
        timestamp: Date,
        kind: PulseAgentStatusEventKind,
        message: String?,
        parentSessionID: String? = nil,
        isSubagent: Bool = false,
        transcriptPath: String? = nil,
        turnID: String? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.sessionTitle = sessionTitle
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.parentSessionID = parentSessionID
        self.isSubagent = isSubagent
        self.transcriptPath = transcriptPath
        self.turnID = turnID
    }
}

struct AgentSessionSlot: Identifiable, Codable, Equatable {
    let id: UUID
    let agent: AgentStatusAgent
    var sessionID: String?
    var projectPath: String?
    var projectName: String?
    var sessionTitle: String?
    var state: AgentSessionLightState
    var sessionState: AgentSessionLightState?
    var lastTransitionAt: Date?
    var lastSeenAt: Date?

    init(
        id: UUID,
        agent: AgentStatusAgent,
        sessionID: String?,
        projectPath: String?,
        projectName: String?,
        sessionTitle: String?,
        state: AgentSessionLightState,
        sessionState: AgentSessionLightState? = nil,
        lastTransitionAt: Date?,
        lastSeenAt: Date?
    ) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.projectName = projectName
        self.sessionTitle = sessionTitle
        self.state = state
        self.sessionState = sessionState
        self.lastTransitionAt = lastTransitionAt
        self.lastSeenAt = lastSeenAt
    }

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

@MainActor
@Observable
final class AgentStatusPanelSelection {
    var selectedAgent: AgentStatusAgent

    init(selectedAgent: AgentStatusAgent = .openCode) {
        self.selectedAgent = selectedAgent
    }
}
