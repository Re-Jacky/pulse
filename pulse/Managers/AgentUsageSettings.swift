import Foundation
import Combine

final class AgentUsageSettings: ObservableObject {
    static let userDefaultsKey = "agentUsageEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        isEnabled = userDefaults.object(forKey: Self.userDefaultsKey) as? Bool ?? false
    }
}
