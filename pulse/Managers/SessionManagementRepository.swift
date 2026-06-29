import Foundation

protocol SessionManagementRepositorying {
    func loadManagedSessions() throws -> [ManagedSessionSummary]
    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn]
    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction
}

struct SessionManagementRepository: SessionManagementRepositorying {
    func loadManagedSessions() throws -> [ManagedSessionSummary] {
        let openCodeDatabaseURL = OpenCodeUsageQuery.resolveDatabaseURL()
        let openCode = try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
            .sessions
            .map { session in
                ManagedSessionSummary(
                    id: "opencode::\(session.id)",
                    source: .openCode,
                    rawSessionID: openCodeRawSessionID(from: session.id),
                    title: session.title,
                    projectPath: session.directory,
                    projectName: session.shortProjectName,
                    subtitle: OpenCodeUsageSnapshot.modelDisplayName(
                        providerID: session.modelProviderID,
                        modelID: session.modelID,
                        variant: session.modelVariant
                    ),
                    updatedAt: session.updatedAt
                )
            }

        let codex = try CodexUsageQuery.loadMergedSnapshot()
            .sessions
            .filter { $0.isSubagent == false }
            .map { session in
                ManagedSessionSummary(
                    id: "codex::\(session.id)",
                    source: .codex,
                    rawSessionID: session.id,
                    title: session.title,
                    projectPath: session.cwd,
                    projectName: session.shortProjectName,
                    subtitle: "\(session.modelProvider) / \(session.model)",
                    updatedAt: session.updatedAt
                )
            }

        return (openCode + codex).sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn] {
        switch session.source {
        case .openCode:
            return try OpenCodeUsageQuery.loadTranscript(
                databaseURL: OpenCodeUsageQuery.resolveDatabaseURL(),
                sessionID: session.rawSessionID
            )
        case .codex:
            return try CodexUsageQuery.loadTranscript(threadID: session.rawSessionID)
        case .all:
            return []
        }
    }

    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction {
        switch session.source {
        case .openCode:
            return .openCode(command: "opencode resume \(session.rawSessionID)")
        case .codex:
            return .codex(command: "codex resume \(session.rawSessionID)")
        case .all:
            return .codex(command: "")
        }
    }

    private func openCodeRawSessionID(from compoundID: String) -> String {
        compoundID.components(separatedBy: "::").first ?? compoundID
    }
}
