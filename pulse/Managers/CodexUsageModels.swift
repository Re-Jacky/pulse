import Foundation

struct CodexSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let modelProvider: String
    let tokensUsed: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let cacheReadTokens: Int?
    let reasoningEffort: String
    let threadSource: String
    let agentNickname: String?
    let agentRole: String?
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
        reasoningTokens: Int?,
        cacheReadTokens: Int?,
        reasoningEffort: String,
        threadSource: String,
        agentNickname: String?,
        agentRole: String?,
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
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningEffort = reasoningEffort
        self.threadSource = threadSource
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptURL = transcriptURL
    }

    var shortProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var isSubagent: Bool {
        threadSource == "subagent"
    }
}

struct CodexDailyBucket: Codable, Equatable {
    let sessionID: String
    let day: Int

    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let latestActivityAt: Date?

    init(
        sessionID: String,
        day: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        requestCount: Int = 0,
        latestActivityAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.latestActivityAt = latestActivityAt
    }

    static func zero(sessionID: String, day: Int) -> CodexDailyBucket {
        CodexDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 0,
            requestCount: 0,
            latestActivityAt: nil
        )
    }

    func merging(_ other: CodexDailyBucket) -> CodexDailyBucket {
        let mergedLatestActivityAt: Date?
        switch (latestActivityAt, other.latestActivityAt) {
        case let (lhs?, rhs?):
            mergedLatestActivityAt = max(lhs, rhs)
        case let (lhs?, nil):
            mergedLatestActivityAt = lhs
        case let (nil, rhs?):
            mergedLatestActivityAt = rhs
        case (nil, nil):
            mergedLatestActivityAt = nil
        }

        return CodexDailyBucket(
            sessionID: sessionID,
            day: day,
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningTokens: reasoningTokens + other.reasoningTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            totalTokens: totalTokens + other.totalTokens,
            requestCount: requestCount + other.requestCount,
            latestActivityAt: mergedLatestActivityAt
        )
    }
}

struct CodexProjectOption: Identifiable, Equatable {
    let id: String
    let directory: String
    let shortName: String
    let summary: AgentUsageSummary
}

struct CodexSessionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let modelDisplayName: String
    let reasoningEffort: String
    let summary: AgentUsageSummary
    let updatedAt: Date
}

struct CodexModelBreakdown: Identifiable, Equatable {
    var id: String { "\(modelProvider)/\(model)" }
    let modelProvider: String
    let model: String
    let summary: AgentUsageSummary
}

struct CodexSubagentEdge: Equatable {
    let parentThreadID: String
    let childThreadID: String
    let status: String
}

struct CodexGoal: Identifiable, Equatable {
    let id: String
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int?
    let tokensUsed: Int

    var statusColor: String {
        switch status {
        case "active": return "green"
        case "paused": return "yellow"
        case "budget_limited", "usage_limited": return "red"
        case "complete": return "gray"
        default: return "gray"
        }
    }
}

struct CodexSessionDetail: Equatable {
    let threadID: String
    let edges: [CodexSubagentEdge]
    let goals: [CodexGoal]

    var isEmpty: Bool {
        edges.isEmpty && goals.isEmpty
    }
}

struct CodexUsageSnapshot: Equatable {
    let sessions: [CodexSessionRecord]

    init(sessions: [CodexSessionRecord]) {
        self.sessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func filtered(to range: AgentTimeRange, now: Date = Date()) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            sessions: sessions.filter { range.contains($0.updatedAt, now: now) }
        )
    }

    var projectOptions: [CodexProjectOption] {
        Dictionary(grouping: sessions, by: \.cwd)
            .map { directory, sessions in
                CodexProjectOption(
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

    func sessionOptions(for directory: String) -> [CodexSessionOption] {
        sessions
            .filter { $0.cwd == directory && $0.isSubagent == false }
            .map { session in
                CodexSessionOption(
                    id: session.id,
                    title: session.title,
                    directory: session.cwd,
                    modelDisplayName: "\(session.modelProvider) / \(session.model)",
                    reasoningEffort: session.reasoningEffort,
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
            return Self.makeSummary(from: sessions.filter { $0.isSubagent == false })
        case .project(let directory):
            return Self.makeSummary(from: sessions.filter { $0.cwd == directory && $0.isSubagent == false })
        case .session(_, let sessionID):
            return Self.makeSummary(from: sessions.filter { $0.id == sessionID })
        }
    }

    func modelBreakdown(for scope: AgentScope) -> [CodexModelBreakdown] {
        let source: [CodexSessionRecord]

        switch scope {
        case .allProjects:
            source = sessions.filter { $0.isSubagent == false }
        case .project(let directory):
            source = sessions.filter { $0.cwd == directory && $0.isSubagent == false }
        case .session:
            return []
        }

        return Dictionary(grouping: source) { "\($0.modelProvider)/\($0.model)" }
            .compactMap { _, sessions in
                guard let first = sessions.first else { return nil }
                return CodexModelBreakdown(
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
        let source: [CodexSessionRecord]

        switch scope {
        case .allProjects:
            source = sessions.filter { $0.isSubagent == false }
        case .project(let directory):
            source = sessions.filter { $0.cwd == directory && $0.isSubagent == false }
        case .session:
            return []
        }

        return Dictionary(grouping: source) { $0.modelProvider }
            .compactMap { provider, sessions in
                ProviderBreakdown(
                    provider: provider,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    static func makeSummary(from sessions: [CodexSessionRecord]) -> AgentUsageSummary {
        let inputTokens = reduceOptional(\.inputTokens, sessions: sessions)
        let cacheReadTokens = reduceOptional(\.cacheReadTokens, sessions: sessions)
        let totalTokens = sessions.reduce(0) { $0 + $1.tokensUsed }
        let cacheHitDenominatorTokens = cacheReadTokens == nil ? nil : totalTokens

        return AgentUsageSummary(
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: reduceOptional(\.outputTokens, sessions: sessions),
            reasoningTokens: reduceOptional(\.reasoningTokens, sessions: sessions),
            cacheReadTokens: cacheReadTokens,
            cacheHitDenominatorTokens: cacheHitDenominatorTokens,
            cacheWriteTokens: nil,
            requestCount: 0,
            sessionsCount: sessions.count,
            cost: nil,
            lastUpdated: sessions.map(\.updatedAt).max()
        )
    }

    private static func reduceOptional(
        _ keyPath: KeyPath<CodexSessionRecord, Int?>,
        sessions: [CodexSessionRecord]
    ) -> Int? {
        let values = sessions.compactMap { $0[keyPath: keyPath] }
        guard values.isEmpty == false else { return nil }
        return values.reduce(0, +)
    }
}
