import Foundation

enum AgentSource: String, CaseIterable, Identifiable, Hashable, Codable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"
    case claudeCode = "claudecode"

    static let selectableCases: [AgentSource] = [.openCode, .codex, .claudeCode]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .openCode: return "OpenCode"
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
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
        let calendar = Calendar.autoupdatingCurrent
        switch self {
        case .allTime: return true
        case .today:
            return agentUsageDayIdentifier(for: date, calendar: calendar) == agentUsageDayIdentifier(for: now, calendar: calendar)
        case .last7Days:
            let currentDay = agentUsageDayIdentifier(for: now, calendar: calendar)
            return agentUsageDayIdentifier(for: date, calendar: calendar) >= currentDay - 6
        case .last30Days:
            let currentDay = agentUsageDayIdentifier(for: now, calendar: calendar)
            return agentUsageDayIdentifier(for: date, calendar: calendar) >= currentDay - 29
        }
    }
}

typealias AgentTimeRange = AgentDatePreset

enum AgentDateSelection: Equatable, Hashable {
    case preset(AgentDatePreset)
    case singleDay(Int)
    case dayRange(startDay: Int, endDay: Int)

    var preset: AgentDatePreset? {
        guard case let .preset(preset) = self else { return nil }
        return preset
    }

    var displayLabel: String {
        switch self {
        case let .preset(preset):
            return preset.label
        case .singleDay, .dayRange:
            return "Custom Range"
        }
    }
}

enum AgentDateSelectionStorage {
    static let legacyPresetKey = "agentUsageSelectedTimeRange"
    static let kindKey = "agentUsageDateSelectionKind"
    static let presetKey = "agentUsageDatePreset"
    static let startDayKey = "agentUsageDateStartDay"
    static let endDayKey = "agentUsageDateEndDay"

    static func load(
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) -> AgentDateSelection {
        if let kind = userDefaults.string(forKey: kindKey) {
            switch kind {
            case "preset":
                if let preset = loadPresetSelection(from: userDefaults) {
                    return .preset(preset)
                }
            case "single":
                if let singleDay = loadSingleDaySelection(from: userDefaults) {
                    return .singleDay(singleDay)
                }
            case "range":
                if let range = loadRangeSelection(from: userDefaults) {
                    return .dayRange(startDay: range.startDay, endDay: range.endDay)
                }
            default:
                break
            }
        }

        if let legacyPreset = userDefaults.string(forKey: legacyPresetKey),
           let preset = AgentDatePreset(rawValue: legacyPreset) {
            return .preset(preset)
        }

        return .preset(.today)
    }

    static func save(_ selection: AgentDateSelection, userDefaults: UserDefaults = .standard) {
        switch selection {
        case let .preset(preset):
            userDefaults.set("preset", forKey: kindKey)
            userDefaults.set(preset.rawValue, forKey: presetKey)
            userDefaults.removeObject(forKey: startDayKey)
            userDefaults.removeObject(forKey: endDayKey)
        case let .singleDay(day):
            userDefaults.set("single", forKey: kindKey)
            userDefaults.set(day, forKey: startDayKey)
            userDefaults.removeObject(forKey: presetKey)
            userDefaults.removeObject(forKey: endDayKey)
        case let .dayRange(startDay, endDay):
            userDefaults.set("range", forKey: kindKey)
            userDefaults.set(startDay, forKey: startDayKey)
            userDefaults.set(endDay, forKey: endDayKey)
            userDefaults.removeObject(forKey: presetKey)
        }
    }

    private static func loadPresetSelection(from userDefaults: UserDefaults) -> AgentDatePreset? {
        guard let rawValue = userDefaults.string(forKey: presetKey),
              let preset = AgentDatePreset(rawValue: rawValue) else {
            return nil
        }

        return preset
    }

    private static func loadSingleDaySelection(from userDefaults: UserDefaults) -> Int? {
        guard userDefaults.object(forKey: startDayKey) != nil else {
            return nil
        }

        return userDefaults.object(forKey: startDayKey) as? Int
    }

    private static func loadRangeSelection(from userDefaults: UserDefaults) -> (startDay: Int, endDay: Int)? {
        guard userDefaults.object(forKey: startDayKey) != nil,
              userDefaults.object(forKey: endDayKey) != nil else {
            return nil
        }

        guard let startDay = userDefaults.object(forKey: startDayKey) as? Int,
              let endDay = userDefaults.object(forKey: endDayKey) as? Int else {
            return nil
        }

        return (startDay: startDay, endDay: endDay)
    }
}

enum AgentDateSelectionDraftStorage {
    static let kindKey = "agentUsageCustomDraftKind"
    static let startDayKey = "agentUsageCustomDraftStartDay"
    static let endDayKey = "agentUsageCustomDraftEndDay"

    static func load(userDefaults: UserDefaults = .standard) -> AgentDateSelection? {
        guard let kind = userDefaults.string(forKey: kindKey) else {
            return nil
        }

        switch kind {
        case "single":
            guard let day = userDefaults.object(forKey: startDayKey) as? Int else {
                return nil
            }
            return .singleDay(day)
        case "range":
            guard let startDay = userDefaults.object(forKey: startDayKey) as? Int,
                  let endDay = userDefaults.object(forKey: endDayKey) as? Int else {
                return nil
            }
            return .dayRange(startDay: startDay, endDay: endDay)
        default:
            return nil
        }
    }

    static func save(_ selection: AgentDateSelection, userDefaults: UserDefaults = .standard) {
        switch selection {
        case .preset:
            return
        case let .singleDay(day):
            userDefaults.set("single", forKey: kindKey)
            userDefaults.set(day, forKey: startDayKey)
            userDefaults.removeObject(forKey: endDayKey)
        case let .dayRange(startDay, endDay):
            userDefaults.set("range", forKey: kindKey)
            userDefaults.set(startDay, forKey: startDayKey)
            userDefaults.set(endDay, forKey: endDayKey)
        }
    }
}

func agentUsageDayIdentifier(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
    Int(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000) / 86_400_000
}

func dateForAgentUsageDayIdentifier(_ day: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
    var date = Date(timeIntervalSince1970: Double(day * 86_400_000) / 1000)
    while agentUsageDayIdentifier(for: date, calendar: calendar) < day {
        date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
    }
    while agentUsageDayIdentifier(for: date, calendar: calendar) > day {
        date = calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
    }
    return calendar.startOfDay(for: date)
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
    let cacheHitDenominatorTokens: Int?
    let cacheWriteTokens: Int?
    let requestCount: Int
    let sessionsCount: Int
    let cost: Double?
    let lastUpdated: Date?
}

struct AgentUsageProviderRawIdentity: Codable, Equatable, Hashable, Identifiable {
    let source: AgentSource
    let rawProviderID: String
    let rawProviderName: String

    var id: String {
        [source.rawValue, rawProviderID, rawProviderName].joined(separator: "::")
    }

    var rawDisplayName: String {
        rawProviderName.isEmpty ? rawProviderID : rawProviderName
    }

    var sourceQualifiedDisplayName: String {
        "\(source.displayName) / \(rawDisplayName)"
    }
}

struct AgentUsageModelRawIdentity: Codable, Equatable, Hashable, Identifiable {
    let source: AgentSource
    let rawProviderID: String
    let rawProviderName: String
    let rawModelID: String
    let rawModelName: String
    let rawModelVariant: String?

    var id: String {
        [
            source.rawValue,
            rawProviderID,
            rawProviderName,
            rawModelID,
            rawModelName,
            rawModelVariant ?? ""
        ].joined(separator: "::")
    }

    var rawProviderDisplayName: String {
        rawProviderName.isEmpty ? rawProviderID : rawProviderName
    }

    var rawModelDisplayName: String {
        rawModelName.isEmpty ? rawModelID : rawModelName
    }

    var sourceQualifiedDisplayName: String {
        let variantSuffix: String
        if let rawModelVariant, rawModelVariant.isEmpty == false {
            variantSuffix = " (\(rawModelVariant))"
        } else {
            variantSuffix = ""
        }

        return "\(source.displayName) / \(rawProviderDisplayName) / \(rawModelDisplayName)\(variantSuffix)"
    }
}

struct AgentUsageProviderDisplayMapping: Codable, Equatable {
    let identity: AgentUsageProviderRawIdentity
    let displayProviderName: String
}

struct AgentUsageModelDisplayMapping: Codable, Equatable {
    let identity: AgentUsageModelRawIdentity
    let displayProviderName: String
    let displayModelName: String
}

struct AgentUsageProviderMappingCandidate: Equatable, Identifiable {
    let identity: AgentUsageProviderRawIdentity
    let totalTokens: Int

    var id: String { identity.id }
}

struct AgentUsageModelMappingCandidate: Equatable, Identifiable {
    let identity: AgentUsageModelRawIdentity
    let totalTokens: Int

    var id: String { identity.id }
}

extension AgentUsageSummary {
    static func merge(_ a: AgentUsageSummary, _ b: AgentUsageSummary) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: a.totalTokens + b.totalTokens,
            inputTokens: mergeOptional(a.inputTokens, b.inputTokens, +),
            outputTokens: mergeOptional(a.outputTokens, b.outputTokens, +),
            reasoningTokens: mergeOptional(a.reasoningTokens, b.reasoningTokens, +),
            cacheReadTokens: mergeOptional(a.cacheReadTokens, b.cacheReadTokens, +),
            cacheHitDenominatorTokens: mergeOptional(a.cacheHitDenominatorTokens, b.cacheHitDenominatorTokens, +),
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
    static func message(for source: AgentSource, openCodeDatabaseURL: URL, codexDatabaseURL: URL?, claudeCodeProjectsURL: URL) -> String {
        switch source {
        case .all:
            let codexDescription = codexDatabaseURL?.path ?? "Codex state DB not found"
            return "Pulse reads OpenCode usage from \(openCodeDatabaseURL.path), reads Codex session metadata from \(codexDescription), derives Codex token usage from local transcripts under ~/.codex, and reads Claude Code usage from transcripts under \(claudeCodeProjectsURL.path) when you refresh the panel."
        case .openCode:
            return "Pulse reads this agent's local usage data from \(openCodeDatabaseURL.path) when you refresh the panel."
        case .codex:
            let codexDescription = codexDatabaseURL?.path ?? "Codex state DB not found"
            return "Pulse reads Codex session metadata from \(codexDescription) and derives token usage from local transcripts under ~/.codex when you refresh the panel."
        case .claudeCode:
            return "Pulse reads Claude Code token usage from local transcripts under \(claudeCodeProjectsURL.path) when you refresh the panel."
        }
    }
}
