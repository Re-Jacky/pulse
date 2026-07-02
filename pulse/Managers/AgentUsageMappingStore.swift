import Combine
import Foundation

protocol AgentUsageMappingPersistence {
    func load() -> PersistedAgentUsageMappings?
    func save(_ mappings: PersistedAgentUsageMappings)
}

final class InMemoryAgentUsageMappingPersistence: AgentUsageMappingPersistence {
    private var stored: PersistedAgentUsageMappings?

    func load() -> PersistedAgentUsageMappings? {
        stored
    }

    func save(_ mappings: PersistedAgentUsageMappings) {
        stored = mappings
    }
}

final class UserDefaultsAgentUsageMappingPersistence: AgentUsageMappingPersistence {
    private let defaults: UserDefaults
    private let key = "agentUsageMappings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedAgentUsageMappings? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(PersistedAgentUsageMappings.self, from: data)
    }

    func save(_ mappings: PersistedAgentUsageMappings) {
        guard let data = try? JSONEncoder().encode(mappings) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}

struct PersistedAgentUsageMappings: Codable, Equatable {
    var providerMappings: [AgentUsageProviderDisplayMapping]
    var modelMappings: [AgentUsageModelDisplayMapping]
    var providerDisplayNames: [String]
    var modelDisplayNames: [String]

    static let empty = PersistedAgentUsageMappings(
        providerMappings: [],
        modelMappings: [],
        providerDisplayNames: [],
        modelDisplayNames: []
    )
}

final class AgentUsageMappingStore: ObservableObject {
    @Published private(set) var persistedMappings: PersistedAgentUsageMappings

    private let persistence: AgentUsageMappingPersistence

    init(persistence: AgentUsageMappingPersistence = UserDefaultsAgentUsageMappingPersistence()) {
        self.persistence = persistence
        persistedMappings = persistence.load() ?? .empty
    }

    func displayProviderName(for identity: AgentUsageProviderRawIdentity) -> String? {
        persistedMappings.providerMappings
            .first { $0.identity == identity }?
            .displayProviderName
    }

    func displayModelMapping(for identity: AgentUsageModelRawIdentity) -> AgentUsageModelDisplayMapping? {
        persistedMappings.modelMappings.first { $0.identity == identity }
    }

    func upsertProviderMapping(_ mapping: AgentUsageProviderDisplayMapping) {
        let displayProviderName = mapping.displayProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayProviderName.isEmpty == false else {
            resetProviderMapping(for: mapping.identity)
            return
        }

        persistedMappings.providerMappings.removeAll { $0.identity == mapping.identity }
        persistedMappings.providerMappings.append(
            AgentUsageProviderDisplayMapping(
                identity: mapping.identity,
                displayProviderName: displayProviderName
            )
        )
        persist()
    }

    func upsertModelMapping(_ mapping: AgentUsageModelDisplayMapping) {
        let displayProviderName = mapping.displayProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayModelName = mapping.displayModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayProviderName.isEmpty == false, displayModelName.isEmpty == false else {
            resetModelMapping(for: mapping.identity)
            return
        }

        persistedMappings.modelMappings.removeAll { $0.identity == mapping.identity }
        persistedMappings.modelMappings.append(
            AgentUsageModelDisplayMapping(
                identity: mapping.identity,
                displayProviderName: displayProviderName,
                displayModelName: displayModelName
            )
        )
        persist()
    }

    func resetProviderMapping(for identity: AgentUsageProviderRawIdentity) {
        persistedMappings.providerMappings.removeAll { $0.identity == identity }
        persist()
    }

    func resetModelMapping(for identity: AgentUsageModelRawIdentity) {
        persistedMappings.modelMappings.removeAll { $0.identity == identity }
        persist()
    }

    func addProviderDisplayName(_ displayName: String) {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        guard persistedMappings.providerDisplayNames.contains(normalized) == false else { return }
        persistedMappings.providerDisplayNames.append(normalized)
        persistedMappings.providerDisplayNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persist()
    }

    func addModelDisplayName(_ displayName: String) {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        guard persistedMappings.modelDisplayNames.contains(normalized) == false else { return }
        persistedMappings.modelDisplayNames.append(normalized)
        persistedMappings.modelDisplayNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persist()
    }

    func removeProviderDisplayName(_ displayName: String) {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }

        persistedMappings.providerDisplayNames.removeAll { $0 == normalized }
        persistedMappings.providerMappings.removeAll { $0.displayProviderName == normalized }
        persistedMappings.modelMappings.removeAll { $0.displayProviderName == normalized }
        persist()
    }

    func removeModelDisplayName(_ displayName: String) {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }

        persistedMappings.modelDisplayNames.removeAll { $0 == normalized }
        persistedMappings.modelMappings.removeAll { $0.displayModelName == normalized }
        persist()
    }

    var providerDisplayNames: [String] {
        persistedMappings.providerDisplayNames
    }

    var modelDisplayNames: [String] {
        persistedMappings.modelDisplayNames
    }

    private func persist() {
        persistence.save(persistedMappings)
    }
}
