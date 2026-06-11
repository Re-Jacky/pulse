import Foundation

struct CodexSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let modelProvider: String
    let tokensUsed: Int
    let reasoningEffort: String
    let threadSource: String
    let agentNickname: String?
    let agentRole: String?
    let createdAt: Date
    let updatedAt: Date

    var shortProjectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var isSubagent: Bool {
        threadSource == "subagent"
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
        AgentUsageSummary(
            totalTokens: sessions.reduce(0) { $0 + $1.tokensUsed },
            inputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            sessionsCount: sessions.count,
            cost: nil,
            lastUpdated: sessions.map(\.updatedAt).max()
        )
    }
}
