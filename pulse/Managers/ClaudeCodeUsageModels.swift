import Foundation

struct ClaudeCodeSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let modelProvider: String
    let tokensUsed: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let createdAt: Date
    let updatedAt: Date
    let transcriptURL: URL?

    init(
        id: String,
        title: String,
        cwd: String,
        model: String,
        modelProvider: String,
        tokensUsed: Int,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        createdAt: Date,
        updatedAt: Date,
        transcriptURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.model = model
        self.modelProvider = modelProvider
        self.tokensUsed = tokensUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptURL = transcriptURL
    }

    var shortProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct ClaudeCodeDailyBucket: Codable, Equatable {
    let sessionID: String
    let day: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let latestActivityAt: Date?

    static func zero(sessionID: String, day: Int) -> ClaudeCodeDailyBucket {
        ClaudeCodeDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 0,
            requestCount: 0,
            latestActivityAt: nil
        )
    }

    func merging(_ other: ClaudeCodeDailyBucket) -> ClaudeCodeDailyBucket {
        let mergedLatestActivityAt: Date?
        switch (latestActivityAt, other.latestActivityAt) {
        case let (lhs?, rhs?): mergedLatestActivityAt = max(lhs, rhs)
        case let (lhs?, nil): mergedLatestActivityAt = lhs
        case let (nil, rhs?): mergedLatestActivityAt = rhs
        case (nil, nil): mergedLatestActivityAt = nil
        }

        return ClaudeCodeDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
            totalTokens: totalTokens + other.totalTokens,
            requestCount: requestCount + other.requestCount,
            latestActivityAt: mergedLatestActivityAt
        )
    }
}

struct ClaudeCodeProjectOption: Identifiable, Equatable {
    let id: String
    let directory: String
    let shortName: String
    let summary: AgentUsageSummary
}

struct ClaudeCodeSessionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let modelDisplayName: String
    let summary: AgentUsageSummary
    let updatedAt: Date
}

struct ClaudeCodeModelBreakdown: Identifiable, Equatable {
    var id: String { "\(modelProvider)/\(model)" }
    let modelProvider: String
    let model: String
    let summary: AgentUsageSummary
}

struct ClaudeCodeUsageSnapshot: Equatable {
    let sessions: [ClaudeCodeSessionRecord]

    init(sessions: [ClaudeCodeSessionRecord]) {
        self.sessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func filtered(to range: AgentTimeRange, now: Date = Date()) -> ClaudeCodeUsageSnapshot {
        ClaudeCodeUsageSnapshot(
            sessions: sessions.filter { range.contains($0.updatedAt, now: now) }
        )
    }

    var projectOptions: [ClaudeCodeProjectOption] {
        Dictionary(grouping: sessions, by: \.cwd)
            .map { directory, sessions in
                ClaudeCodeProjectOption(
                    id: directory,
                    directory: directory,
                    shortName: URL(fileURLWithPath: directory).lastPathComponent,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.shortName.localizedCaseInsensitiveCompare(rhs.shortName) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func sessionOptions(for directory: String) -> [ClaudeCodeSessionOption] {
        sessions
            .filter { $0.cwd == directory }
            .map { session in
                ClaudeCodeSessionOption(
                    id: session.id,
                    title: session.title,
                    directory: session.cwd,
                    modelDisplayName: "\(session.modelProvider) / \(session.model)",
                    summary: Self.makeSummary(from: [session]),
                    updatedAt: session.updatedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func summary(for scope: AgentScope) -> AgentUsageSummary {
        switch scope {
        case .allProjects:
            return Self.makeSummary(from: sessions)
        case .project(let directory):
            return Self.makeSummary(from: sessions.filter { $0.cwd == directory })
        case .session(_, let sessionID):
            return Self.makeSummary(from: sessions.filter { $0.id == sessionID })
        }
    }

    func modelBreakdown(for scope: AgentScope) -> [ClaudeCodeModelBreakdown] {
        let source: [ClaudeCodeSessionRecord]
        switch scope {
        case .allProjects: source = sessions
        case .project(let directory): source = sessions.filter { $0.cwd == directory }
        case .session: return []
        }

        return Dictionary(grouping: source) { "\($0.modelProvider)/\($0.model)" }
            .compactMap { _, sessions in
                guard let first = sessions.first else { return nil }
                return ClaudeCodeModelBreakdown(
                    modelProvider: first.modelProvider,
                    model: first.model,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
    }

    func providerBreakdown(for scope: AgentScope) -> [ProviderBreakdown] {
        let source: [ClaudeCodeSessionRecord]
        switch scope {
        case .allProjects: source = sessions
        case .project(let directory): source = sessions.filter { $0.cwd == directory }
        case .session: return []
        }

        return Dictionary(grouping: source) { $0.modelProvider }
            .compactMap { provider, sessions in
                ProviderBreakdown(provider: provider, summary: Self.makeSummary(from: sessions))
            }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    static func makeSummary(from sessions: [ClaudeCodeSessionRecord]) -> AgentUsageSummary {
        // requestCount is intentionally 0 here: the store enriches request counts
        // from daily buckets (one per assistant message carrying a usage dict).
        let inputTokens = reduceOptional(\.inputTokens, sessions: sessions)
        let cacheReadTokens = reduceOptional(\.cacheReadTokens, sessions: sessions)
        let totalTokens = sessions.reduce(0) { $0 + $1.tokensUsed }
        let cacheHitDenominatorTokens = cacheReadTokens == nil ? nil : totalTokens

        return AgentUsageSummary(
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: reduceOptional(\.outputTokens, sessions: sessions),
            reasoningTokens: nil,
            cacheReadTokens: cacheReadTokens,
            cacheHitDenominatorTokens: cacheHitDenominatorTokens,
            cacheWriteTokens: reduceOptional(\.cacheWriteTokens, sessions: sessions),
            requestCount: 0,
            sessionsCount: sessions.count,
            cost: nil,
            lastUpdated: sessions.map(\.updatedAt).max()
        )
    }

    private static func reduceOptional(
        _ keyPath: KeyPath<ClaudeCodeSessionRecord, Int?>,
        sessions: [ClaudeCodeSessionRecord]
    ) -> Int? {
        let values = sessions.compactMap { $0[keyPath: keyPath] }
        guard values.isEmpty == false else { return nil }
        return values.reduce(0, +)
    }
}
