import Foundation

enum SessionManagerSourceFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }
}

struct ManagedSessionsPartialUpdate: Equatable {
    let sessions: [ManagedSessionSummary]
    let loadedSources: Set<AgentSource>
}

enum ManagedSessionKind: Equatable {
    case openCode(OpenCodeSessionRecord)
    case codex(CodexSessionRecord)
}

struct ManagedSessionSummary: Identifiable, Equatable {
    let id: String
    let source: AgentSource
    let rawSessionID: String
    let title: String
    let projectPath: String
    let projectName: String
    let subtitle: String
    let updatedAt: Date
    let transcriptURL: URL?
}

enum TranscriptTurnRole: String, Equatable {
    case user
    case assistant
    case system
    case unknown
}

struct TranscriptTurn: Identifiable, Equatable {
    let id: String
    let role: TranscriptTurnRole
    let text: String
    let timestamp: Date?
}

enum TranscriptLoadState: Equatable {
    case idle
    case loading([TranscriptTurn])
    case loaded([TranscriptTurn])
    case failed(String)
}

enum SessionListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum ResumeAction: Equatable {
    case openCode(command: String)
    case codex(command: String)
    case claudeCode(command: String)
}
