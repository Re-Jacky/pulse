import Foundation
import Combine

final class AgentUsageSettings: ObservableObject {
    static let userDefaultsKey = "agentUsageEnabled"
    static let selectedSourcesUserDefaultsKey = "agentUsageSelectedSources"

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
