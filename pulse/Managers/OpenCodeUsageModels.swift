import Foundation

struct OpenCodeSessionRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let agent: String
    let modelProviderID: String
    let modelID: String
    let modelVariant: String?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let requestCount: Int
    let cost: Double
    let createdAt: Date
    let updatedAt: Date

    var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheWriteTokens
    }

    var shortProjectName: String {
        URL(fileURLWithPath: directory).lastPathComponent
    }
}

struct OpenCodeProjectOption: Identifiable, Equatable {
let id: String
let directory: String
let shortName: String
let summary: AgentUsageSummary
}

struct OpenCodeSessionOption: Identifiable, Equatable {
let id: String
let title: String
let directory: String
let agent: String
let modelDisplayName: String
let summary: AgentUsageSummary
let updatedAt: Date
}

struct OpenCodeModelBreakdown: Identifiable, Equatable {
var id: String { [providerID, modelID, variant ?? ""].joined(separator: "::") }

let providerID: String
let modelID: String
let variant: String?
let summary: AgentUsageSummary
}

struct OpenCodeUsageSnapshot: Equatable {
    let sessions: [OpenCodeSessionRecord]

    init(sessions: [OpenCodeSessionRecord]) {
        self.sessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func filtered(to range: AgentTimeRange, now: Date = Date()) -> OpenCodeUsageSnapshot {
        OpenCodeUsageSnapshot(
            sessions: sessions.filter { range.contains($0.updatedAt, now: now) }
        )
    }

    var projectOptions: [OpenCodeProjectOption] {
        Dictionary(grouping: sessions, by: \.directory)
            .map { directory, sessions in
                OpenCodeProjectOption(
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

    func sessionOptions(for directory: String) -> [OpenCodeSessionOption] {
        sessions
            .filter { $0.directory == directory }
            .map { session in
                OpenCodeSessionOption(
                    id: session.id,
                    title: session.title,
                    directory: session.directory,
                    agent: session.agent,
                    modelDisplayName: Self.modelDisplayName(
                        providerID: session.modelProviderID,
                        modelID: session.modelID,
                        variant: session.modelVariant
                    ),
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
            return Self.makeSummary(from: sessions.filter { $0.directory == directory })
        case .session(_, let sessionID):
            return Self.makeSummary(from: sessions.filter { $0.id == sessionID })
        }
    }

    func modelBreakdown(for scope: AgentScope) -> [OpenCodeModelBreakdown] {
        let source: [OpenCodeSessionRecord]

        switch scope {
        case .allProjects:
            source = sessions
        case .project(let directory):
            source = sessions.filter { $0.directory == directory }
        case .session:
            return []
        }

        return Dictionary(grouping: source) { session in
            [session.modelProviderID, session.modelID, session.modelVariant ?? ""].joined(separator: "::")
        }
        .compactMap { _, sessions in
            guard let first = sessions.first else { return nil }

            return OpenCodeModelBreakdown(
                providerID: first.modelProviderID,
                modelID: first.modelID,
                variant: first.modelVariant,
                summary: Self.makeSummary(from: sessions)
            )
        }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
    }

    func providerBreakdown(for scope: AgentScope) -> [ProviderBreakdown] {
        let source: [OpenCodeSessionRecord]

        switch scope {
        case .allProjects:
            source = sessions
        case .project(let directory):
            source = sessions.filter { $0.directory == directory }
        case .session:
            return []
        }

        return Dictionary(grouping: source) { $0.modelProviderID }
            .compactMap { provider, sessions in
                ProviderBreakdown(
                    provider: provider,
                    summary: Self.makeSummary(from: sessions)
                )
            }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    static func makeSummary(from sessions: [OpenCodeSessionRecord]) -> AgentUsageSummary {
        var totalTokens = 0, input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0, requests = 0
        var cost = 0.0
        var lastUpdated: Date?
        for s in sessions {
            totalTokens += s.totalTokens; input += s.inputTokens; output += s.outputTokens
            reasoning += s.reasoningTokens; cacheRead += s.cacheReadTokens; cacheWrite += s.cacheWriteTokens
            requests += s.requestCount; cost += s.cost
            if lastUpdated == nil || s.updatedAt > lastUpdated! { lastUpdated = s.updatedAt }
        }
        return AgentUsageSummary(
            totalTokens: totalTokens,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheHitDenominatorTokens: input + cacheRead,
            cacheWriteTokens: cacheWrite,
            requestCount: requests,
            sessionsCount: sessions.count,
            cost: cost,
            lastUpdated: lastUpdated
        )
    }

    static func modelDisplayName(providerID: String, modelID: String, variant: String?) -> String {
        guard let variant, variant.isEmpty == false else {
            return "\(providerID) / \(modelID)"
        }

        return "\(providerID) / \(modelID) (\(variant))"
    }
}
