import Foundation

enum AgentSource: String, CaseIterable, Identifiable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .openCode: return "OpenCode"
        case .codex: return "Codex"
        }
    }
}

enum AgentTimeRange: String, CaseIterable, Identifiable {
    case allTime = "all_time"
    case today = "today"
    case last7Days = "last_7_days"
    case last30Days = "last_30_days"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allTime: return "All Time"
        case .today: return "Today"
        case .last7Days: return "7 Days"
        case .last30Days: return "30 Days"
        }
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .allTime: return true
        case .today: return Calendar.current.isDate(date, inSameDayAs: now)
        case .last7Days: return date >= now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .last30Days: return date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }
}

enum AgentScope: Equatable {
    case allProjects
    case project(directory: String)
    case session(projectDirectory: String, sessionID: String)
}

struct AgentUsageSummary: Equatable {
    let totalTokens: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let sessionsCount: Int
    let cost: Double?
    let lastUpdated: Date?
}

extension AgentUsageSummary {
    static func merge(_ a: AgentUsageSummary, _ b: AgentUsageSummary) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: a.totalTokens + b.totalTokens,
            inputTokens: mergeOptional(a.inputTokens, b.inputTokens, +),
            outputTokens: mergeOptional(a.outputTokens, b.outputTokens, +),
            reasoningTokens: mergeOptional(a.reasoningTokens, b.reasoningTokens, +),
            cacheReadTokens: mergeOptional(a.cacheReadTokens, b.cacheReadTokens, +),
            cacheWriteTokens: mergeOptional(a.cacheWriteTokens, b.cacheWriteTokens, +),
            sessionsCount: a.sessionsCount + b.sessionsCount,
            cost: mergeOptional(a.cost, b.cost, +),
            lastUpdated: {
                switch (a.lastUpdated, b.lastUpdated) {
                case let (a?, b?): return max(a, b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }()
        )
    }

    private static func mergeOptional<T: Numeric>(_ a: T?, _ b: T?, _ op: (T, T) -> T) -> T? {
        switch (a, b) {
        case let (a?, b?): return op(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}
