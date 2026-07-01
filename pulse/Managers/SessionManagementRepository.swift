import Foundation

protocol SessionManagementRepositorying {
    func loadManagedSessions() throws -> [ManagedSessionSummary]
    func loadManagedSessions(
        onPartialUpdate: @escaping @Sendable (ManagedSessionsPartialUpdate) -> Void
    ) throws -> [ManagedSessionSummary]
    func loadTranscript(for session: ManagedSessionSummary) throws -> [TranscriptTurn]
    func loadTranscript(
        for session: ManagedSessionSummary,
        onPartialUpdate: @escaping @Sendable ([TranscriptTurn]) -> Void
    ) throws -> [TranscriptTurn]
    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction
}

final class SessionManagementRepository: SessionManagementRepositorying {
    private let resolveOpenCodeDatabaseURL: () -> URL
    private let loadOpenCodeSnapshot: (URL) throws -> OpenCodeUsageSnapshot
    private let loadOpenCodeTranscript: (URL, String) throws -> [TranscriptTurn]
    private let loadOpenCodeTranscriptProgressively: (URL, String, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn]
    private let loadCodexSnapshot: () throws -> CodexUsageSnapshot
    private let loadCodexTranscript: (String, URL?) throws -> [TranscriptTurn]
    private let loadCodexTranscriptProgressively: (String, URL?, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn]

    private var discoveredOpenCodeDatabaseURL: URL?
    private var openCodeDatabaseURLByManagedSessionID: [String: URL] = [:]

    init(
        resolveOpenCodeDatabaseURL: @escaping () -> URL = { OpenCodeUsageQuery.resolveDatabaseURL() },
        loadOpenCodeSnapshot: @escaping (URL) throws -> OpenCodeUsageSnapshot = OpenCodeUsageQuery.loadSnapshot,
        loadOpenCodeTranscript: @escaping (URL, String) throws -> [TranscriptTurn] = OpenCodeUsageQuery.loadTranscript,
        loadOpenCodeTranscriptProgressively: @escaping (URL, String, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn] = {
            try OpenCodeUsageQuery.loadTranscript(databaseURL: $0, sessionID: $1, onPartialUpdate: $2)
        },
        loadCodexSnapshot: @escaping () throws -> CodexUsageSnapshot = {
            try CodexUsageQuery.loadMergedSnapshot(includeTranscriptURLs: false)
        },
        loadCodexTranscript: @escaping (String, URL?) throws -> [TranscriptTurn] = {
            try CodexUsageQuery.loadTranscript(threadID: $0, transcriptURL: $1)
        },
        loadCodexTranscriptProgressively: @escaping (String, URL?, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn] = {
            try CodexUsageQuery.loadTranscript(threadID: $0, transcriptURL: $1, onPartialUpdate: $2)
        }
    ) {
        self.resolveOpenCodeDatabaseURL = resolveOpenCodeDatabaseURL
        self.loadOpenCodeSnapshot = loadOpenCodeSnapshot
        self.loadOpenCodeTranscript = loadOpenCodeTranscript
        self.loadOpenCodeTranscriptProgressively = loadOpenCodeTranscriptProgressively
        self.loadCodexSnapshot = loadCodexSnapshot
        self.loadCodexTranscript = loadCodexTranscript
        self.loadCodexTranscriptProgressively = loadCodexTranscriptProgressively
    }

    convenience init(
        resolveOpenCodeDatabaseURL: @escaping () -> URL,
        loadOpenCodeSnapshot: @escaping (URL) throws -> OpenCodeUsageSnapshot,
        loadOpenCodeTranscript: @escaping (URL, String) throws -> [TranscriptTurn],
        loadCodexSnapshot: @escaping () throws -> CodexUsageSnapshot,
        loadCodexTranscript: @escaping (String, URL?) throws -> [TranscriptTurn],
        loadCodexTranscriptProgressively: @escaping (String, URL?, @escaping @Sendable ([TranscriptTurn]) -> Void) throws -> [TranscriptTurn]
    ) {
        self.init(
            resolveOpenCodeDatabaseURL: resolveOpenCodeDatabaseURL,
            loadOpenCodeSnapshot: loadOpenCodeSnapshot,
            loadOpenCodeTranscript: loadOpenCodeTranscript,
            loadOpenCodeTranscriptProgressively: { databaseURL, sessionID, _ in
                try loadOpenCodeTranscript(databaseURL, sessionID)
            },
            loadCodexSnapshot: loadCodexSnapshot,
            loadCodexTranscript: loadCodexTranscript,
            loadCodexTranscriptProgressively: loadCodexTranscriptProgressively
        )
    }

    func loadManagedSessions() throws -> [ManagedSessionSummary] {
        try loadManagedSessions(onPartialUpdate: { _ in })
    }

    func loadManagedSessions(
        onPartialUpdate: @escaping @Sendable (ManagedSessionsPartialUpdate) -> Void
    ) throws -> [ManagedSessionSummary] {
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
                    updatedAt: session.updatedAt,
                    transcriptURL: nil
                )
            }
            openCodeDatabaseURLByManagedSessionID = databaseURLBySessionID
            onPartialUpdate(
                ManagedSessionsPartialUpdate(
                    sessions: openCodeSessions,
                    loadedSources: [.openCode]
                )
            )
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
                    updatedAt: session.updatedAt,
                    transcriptURL: session.transcriptURL
                )
                }
            codexLoaded = true
            onPartialUpdate(
                ManagedSessionsPartialUpdate(
                    sessions: (openCodeSessions + codexSessions).sorted { lhs, rhs in
                        if lhs.updatedAt == rhs.updatedAt {
                            return lhs.id < rhs.id
                        }
                        return lhs.updatedAt > rhs.updatedAt
                    },
                    loadedSources: Set([
                        openCodeLoaded ? AgentSource.openCode : nil,
                        .codex
                    ].compactMap { $0 })
                )
            )
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
            return try loadTranscript(for: session) { _ in }
        case .all:
            return []
        }
    }

    func loadTranscript(
        for session: ManagedSessionSummary,
        onPartialUpdate: @escaping @Sendable ([TranscriptTurn]) -> Void
    ) throws -> [TranscriptTurn] {
        switch session.source {
        case .openCode:
            let databaseURL = openCodeDatabaseURLByManagedSessionID[session.id]
                ?? discoveredOpenCodeDatabaseURL
                ?? resolveOpenCodeDatabaseURL()
            return try loadOpenCodeTranscriptProgressively(databaseURL, session.rawSessionID, onPartialUpdate)
        case .codex:
            return try loadCodexTranscriptProgressively(session.rawSessionID, session.transcriptURL, onPartialUpdate)
        case .all:
            return []
        }
    }

    func resumeAction(for session: ManagedSessionSummary) -> ResumeAction {
        switch session.source {
        case .openCode:
            return .openCode(command: "opencode --session \(session.rawSessionID)")
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
