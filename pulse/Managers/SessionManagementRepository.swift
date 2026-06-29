import Foundation

protocol SessionManagementRepositorying {
    func loadManagedSessions() throws -> [ManagedSessionSummary]
    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn]
    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction
}

final class SessionManagementRepository: SessionManagementRepositorying {
    private let resolveOpenCodeDatabaseURL: () -> URL
    private let loadOpenCodeSnapshot: (URL) throws -> OpenCodeUsageSnapshot
    private let loadOpenCodeTranscript: (URL, String) throws -> [TranscriptTurn]
    private let loadCodexSnapshot: () throws -> CodexUsageSnapshot
    private let loadCodexTranscript: (String) throws -> [TranscriptTurn]

    private var discoveredOpenCodeDatabaseURL: URL?
    private var openCodeDatabaseURLByManagedSessionID: [String: URL] = [:]

    init(
        resolveOpenCodeDatabaseURL: @escaping () -> URL = { OpenCodeUsageQuery.resolveDatabaseURL() },
        loadOpenCodeSnapshot: @escaping (URL) throws -> OpenCodeUsageSnapshot = OpenCodeUsageQuery.loadSnapshot,
        loadOpenCodeTranscript: @escaping (URL, String) throws -> [TranscriptTurn] = OpenCodeUsageQuery.loadTranscript,
        loadCodexSnapshot: @escaping () throws -> CodexUsageSnapshot = { try CodexUsageQuery.loadMergedSnapshot() },
        loadCodexTranscript: @escaping (String) throws -> [TranscriptTurn] = { try CodexUsageQuery.loadTranscript(threadID: $0) }
    ) {
        self.resolveOpenCodeDatabaseURL = resolveOpenCodeDatabaseURL
        self.loadOpenCodeSnapshot = loadOpenCodeSnapshot
        self.loadOpenCodeTranscript = loadOpenCodeTranscript
        self.loadCodexSnapshot = loadCodexSnapshot
        self.loadCodexTranscript = loadCodexTranscript
    }

    func loadManagedSessions() throws -> [ManagedSessionSummary] {
        var openCodeSessions: [ManagedSessionSummary] = []
        var codexSessions: [ManagedSessionSummary] = []
        var openCodeLoaded = false
        var codexLoaded = false
        var openCodeError: Error?
        var codexError: Error?

        do {
            let openCodeDatabaseURL = resolveOpenCodeDatabaseURL()
            let snapshot = try loadOpenCodeSnapshot(openCodeDatabaseURL)
            openCodeLoaded = true
            discoveredOpenCodeDatabaseURL = openCodeDatabaseURL

            var databaseURLBySessionID: [String: URL] = [:]
            openCodeSessions = snapshot.sessions.map { session in
                let managedSessionID = "opencode::\(session.id)"
                databaseURLBySessionID[managedSessionID] = openCodeDatabaseURL

                return ManagedSessionSummary(
                    id: managedSessionID,
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
            openCodeDatabaseURLByManagedSessionID = databaseURLBySessionID
        } catch {
            openCodeError = error
            discoveredOpenCodeDatabaseURL = nil
            openCodeDatabaseURLByManagedSessionID = [:]
        }

        do {
            codexSessions = try loadCodexSnapshot()
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
            codexLoaded = true
        } catch {
            codexError = error
        }

        guard openCodeLoaded || codexLoaded else {
            throw codexError ?? openCodeError ?? NSError(
                domain: "SessionManagementRepository",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load session sources."]
            )
        }

        return (openCodeSessions + codexSessions).sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn] {
        switch session.source {
        case .openCode:
            let databaseURL = openCodeDatabaseURLByManagedSessionID[session.id]
                ?? discoveredOpenCodeDatabaseURL
                ?? resolveOpenCodeDatabaseURL()
            return try loadOpenCodeTranscript(databaseURL, session.rawSessionID)
        case .codex:
            return try loadCodexTranscript(session.rawSessionID)
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
