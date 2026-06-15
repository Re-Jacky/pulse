import Foundation

enum AgentModelGroupBy: String, Equatable {
    case model
    case provider
}

struct AgentUsageSelection: Equatable {
    let source: AgentSource
    let timeRange: AgentTimeRange
    let projectDirectory: String?
    let sessionID: String?
    let modelGroupBy: AgentModelGroupBy

    var scope: AgentScope {
        guard let projectDirectory else { return .allProjects }
        guard source != .all, let sessionID else {
            return .project(directory: projectDirectory)
        }
        return .session(projectDirectory: projectDirectory, sessionID: sessionID)
    }

    var isSessionScope: Bool {
        if case .session = scope {
            return true
        }
        return false
    }
}

enum CodexSessionDetailState: Equatable {
    case idle
    case loading
    case loaded(CodexSessionDetail)
    case failed(String)
}

struct AgentUsageLoadedState: Equatable {
    let openCodeCumulativeSnapshot: OpenCodeUsageSnapshot
    let openCodeDailyBuckets: [OpenCodeDailyBucket]
    let codexSnapshot: CodexUsageSnapshot
    let refreshGeneration: Int
    let codexDetailCache: [String: CodexSessionDetailState]

    static let empty = AgentUsageLoadedState(
        openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
        openCodeDailyBuckets: [],
        codexSnapshot: CodexUsageSnapshot(sessions: []),
        refreshGeneration: 0,
        codexDetailCache: [:]
    )
}

struct AgentUsageMetricCard: Equatable, Identifiable {
    let id: String
    let title: String
    let valueText: String
    let detailText: String?
}

struct AgentUsageSummaryPill: Equatable, Identifiable {
    let id: String
    let title: String
    let valueText: String
}

struct AgentUsageDetailRow: Equatable, Identifiable {
    let id: String
    let title: String
    let valueText: String
    let secondaryText: String?
}

struct AgentUsageDerivedViewData {
    let selection: AgentUsageSelection
    let scope: AgentScope
    let summary: AgentUsageSummary
    let projectOptions: [SearchableSelectorOption]
    let sessionOptions: [SearchableSelectorOption]
    let tokenFlowData: [TokenUsageDataPoint]
    let usageMetrics: [AgentUsageMetricCard]
    let summaryPills: [AgentUsageSummaryPill]
    let contextRows: [AgentUsageDetailRow]
    let providerBreakdown: [ProviderBreakdown]
    let modelBreakdownRows: [AgentUsageDetailRow]
    let selectedOpenCodeSession: OpenCodeSessionRecord?
    let selectedCodexSession: CodexSessionRecord?
    let codexDetailThreadID: String?
    let isSessionScope: Bool
    let showsByModel: Bool
    let showsTokenFlow: Bool
}
