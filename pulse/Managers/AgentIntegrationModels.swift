import Foundation

enum AgentIntegrationState: Equatable {
    case notInstalled
    case installed
    case installedNeedsRestart
    case installedNeedsActivation
    case outdated
    case installFailed(String)
}

struct AgentIntegrationStatus: Equatable {
    let agent: AgentStatusAgent
    let state: AgentIntegrationState
    let primaryActionTitle: String
    let secondaryActions: [String]
    let guidance: [String]

    var displayStateTitle: String {
        switch state {
        case .notInstalled:
            return "Not Installed"
        case .installed:
            return "Installed"
        case .installedNeedsRestart:
            return "Installed - Restart \(agent.displayName)"
        case .installedNeedsActivation:
            return "Installed - Activate in \(agent.displayName)"
        case .outdated:
            return "Outdated"
        case .installFailed:
            return "Install Failed"
        }
    }
}
