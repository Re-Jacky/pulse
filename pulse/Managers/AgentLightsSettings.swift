import Combine
import Foundation

final class AgentLightsSettings: ObservableObject {
    private enum Keys {
        static let isEnabled = "agentLights.isEnabled"
        static let selectedAgents = "agentLights.selectedAgents"
    }

    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Keys.isEnabled)
        }
    }

    @Published var selectedAgents: Set<AgentStatusAgent> {
        didSet {
            let rawValues = selectedAgents.map(\.rawValue).sorted()
            userDefaults.set(rawValues, forKey: Keys.selectedAgents)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.object(forKey: Keys.isEnabled) as? Bool ?? false

        let savedRawValues = userDefaults.stringArray(forKey: Keys.selectedAgents)
            ?? AgentStatusAgent.allCases.map(\.rawValue)
        let restoredAgents = Set(savedRawValues.compactMap(AgentStatusAgent.init(rawValue:)))
        selectedAgents = restoredAgents.isEmpty ? Set(AgentStatusAgent.allCases) : restoredAgents
    }

    var enabledAgents: [AgentStatusAgent] {
        guard isEnabled else { return [] }
        return AgentStatusAgent.allCases.filter { selectedAgents.contains($0) }
    }
}
