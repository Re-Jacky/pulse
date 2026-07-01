import Foundation

enum AgentSource: String, CaseIterable, Identifiable, Hashable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"

    static let selectableCases: [AgentSource] = [.openCode, .codex]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .openCode: return "OpenCode"
        case .codex: return "Codex"
        }
    }
}

enum AgentDatePreset: String, CaseIterable, Identifiable, Hashable {
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

typealias AgentTimeRange = AgentDatePreset

enum AgentDateSelection: Equatable, Hashable {
    case preset(AgentDatePreset)
    case singleDay(Int)
    case dayRange(startDay: Int, endDay: Int)
}

func agentUsageDayIdentifier(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
    Int(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000) / 86_400_000
}

func agentUsageDayInterval(
    for selection: AgentDateSelection,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
) -> Range<Int>? {
    switch selection {
    case .preset(.allTime):
        return nil
    case .preset(.today):
        let day = agentUsageDayIdentifier(for: now, calendar: calendar)
        return day..<(day + 1)
    case .preset(.last7Days):
        let currentDay = agentUsageDayIdentifier(for: now, calendar: calendar)
        return (currentDay - 6)..<(currentDay + 1)
    case .preset(.last30Days):
        let currentDay = agentUsageDayIdentifier(for: now, calendar: calendar)
        return (currentDay - 29)..<(currentDay + 1)
    case let .singleDay(day):
        return day..<(day + 1)
    case let .dayRange(startDay, endDay):
        let lower = min(startDay, endDay)
        let upper = max(startDay, endDay)
        return lower..<(upper + 1)
    }
}

func agentUsageDayRange(
    for range: AgentTimeRange,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
) -> Range<Int> {
    agentUsageDayInterval(for: .preset(range), now: now, calendar: calendar) ?? 0..<Int.max
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
    let requestCount: Int
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
            requestCount: a.requestCount + b.requestCount,
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

enum AgentUsageDataSourceDescription {
    static func message(for source: AgentSource, openCodeDatabaseURL: URL, codexDatabaseURL: URL?) -> String {
        switch source {
        case .all:
            let codexDescription = codexDatabaseURL?.path ?? "Codex state DB not found"
            return "Pulse reads OpenCode usage from \(openCodeDatabaseURL.path), reads Codex session metadata from \(codexDescription), and derives Codex token usage from local transcripts under ~/.codex when you refresh the panel."
        case .openCode:
            return "Pulse reads this agent's local usage data from \(openCodeDatabaseURL.path) when you refresh the panel."
        case .codex:
            let codexDescription = codexDatabaseURL?.path ?? "Codex state DB not found"
            return "Pulse reads Codex session metadata from \(codexDescription) and derives token usage from local transcripts under ~/.codex when you refresh the panel."
        }
    }
}
