import Foundation
import Combine

enum AgentUsageRefreshIntervalChoice: String, CaseIterable, Identifiable, Codable {
    case seconds30
    case minute1
    case minutes10
    case minutes30
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .seconds30: return "30 seconds"
        case .minute1: return "1 minute"
        case .minutes10: return "10 minutes"
        case .minutes30: return "30 minutes"
        case .custom: return "Custom"
        }
    }
}

enum AgentUsageRefreshIntervalUnit: String, CaseIterable, Identifiable, Codable {
    case seconds
    case minutes
    case hours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .seconds: return "Seconds"
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        }
    }

    var secondsPerUnit: TimeInterval {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 60 * 60
        }
    }
}

struct AgentUsageRefreshInterval: Codable, Equatable {
    var choice: AgentUsageRefreshIntervalChoice
    var customAmount: Int
    var customUnit: AgentUsageRefreshIntervalUnit

    static let defaultValue = AgentUsageRefreshInterval(
        choice: .minutes30,
        customAmount: 1,
        customUnit: .minutes
    )

    var resolvedTimeInterval: TimeInterval? {
        switch choice {
        case .seconds30: return 30
        case .minute1: return 60
        case .minutes10: return 10 * 60
        case .minutes30: return 30 * 60
        case .custom:
            guard customAmount > 0 else { return nil }
            return TimeInterval(customAmount) * customUnit.secondsPerUnit
        }
    }
}

final class AgentUsageSettings: ObservableObject {
    static let userDefaultsKey = "agentUsageEnabled"
    static let selectedSourcesUserDefaultsKey = "agentUsageSelectedSources"
    static let autoRefreshIntervalUserDefaultsKey = "agentUsageAutoRefreshInterval"

    private let userDefaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Self.userDefaultsKey)
        }
    }

    @Published var selectedSources: Set<AgentSource> {
        didSet {
            let rawValues = AgentSource.selectableCases
                .filter { selectedSources.contains($0) }
                .map(\.rawValue)
            userDefaults.set(rawValues, forKey: Self.selectedSourcesUserDefaultsKey)
        }
    }

    @Published var autoRefreshInterval: AgentUsageRefreshInterval {
        didSet {
            guard let data = try? JSONEncoder().encode(autoRefreshInterval) else { return }
            userDefaults.set(data, forKey: Self.autoRefreshIntervalUserDefaultsKey)
        }
    }

    var enabledSources: Set<AgentSource> {
        isEnabled ? selectedSources : []
    }

    var effectiveEnabled: Bool {
        enabledSources.isEmpty == false
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.object(forKey: Self.userDefaultsKey) as? Bool ?? false
        if let savedRawValues = userDefaults.array(forKey: Self.selectedSourcesUserDefaultsKey) as? [String] {
            selectedSources = Set(savedRawValues.compactMap(AgentSource.init(rawValue:)))
        } else {
            selectedSources = Set(AgentSource.selectableCases)
        }

        if let data = userDefaults.data(forKey: Self.autoRefreshIntervalUserDefaultsKey),
           let savedInterval = try? JSONDecoder().decode(AgentUsageRefreshInterval.self, from: data),
           savedInterval.resolvedTimeInterval != nil {
            autoRefreshInterval = savedInterval
        } else {
            autoRefreshInterval = .defaultValue
        }
    }

    static func isEffectivelyEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        let isEnabled = userDefaults.object(forKey: userDefaultsKey) as? Bool ?? false
        guard isEnabled else { return false }

        if let savedRawValues = userDefaults.array(forKey: selectedSourcesUserDefaultsKey) as? [String] {
            return savedRawValues.compactMap(AgentSource.init(rawValue:)).isEmpty == false
        }

        return true
    }
}
