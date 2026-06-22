import Combine
import Foundation

enum AgentLightsAgent: String, CaseIterable, Hashable {
    case openCode = "opencode"
    case codex = "codex"
}

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

    @Published var selectedAgents: Set<AgentLightsAgent> {
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
            ?? AgentLightsAgent.allCases.map(\.rawValue)
        let restoredAgents = Set(savedRawValues.compactMap(AgentLightsAgent.init(rawValue:)))
        selectedAgents = restoredAgents.isEmpty ? Set(AgentLightsAgent.allCases) : restoredAgents
    }

    var enabledAgents: [AgentLightsAgent] {
        guard isEnabled else { return [] }
        return AgentLightsAgent.allCases.filter { selectedAgents.contains($0) }
    }
}
