import XCTest
@testable import Pulse

final class AgentUsageMappingStoreTests: XCTestCase {
    func testProviderRawIdentityHashIncludesSource() {
        let lhs = AgentUsageProviderRawIdentity(
            source: .codex,
            rawProviderID: "custom",
            rawProviderName: "custom"
        )
        let rhs = AgentUsageProviderRawIdentity(
            source: .openCode,
            rawProviderID: "custom",
            rawProviderName: "custom"
        )

        XCTAssertNotEqual(lhs, rhs)
        XCTAssertEqual(Set([lhs, rhs]).count, 2)
    }

    func testMappingStorePersistsProviderAndModelMappings() {
        let suiteName = "AgentUsageMappingStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AgentUsageMappingStore(
            persistence: UserDefaultsAgentUsageMappingPersistence(defaults: defaults)
        )

        let provider = AgentUsageProviderRawIdentity(
            source: .codex,
            rawProviderID: "codex-gpt",
            rawProviderName: "codex-gpt"
        )
        let model = AgentUsageModelRawIdentity(
            source: .codex,
            rawProviderID: "codex-gpt",
            rawProviderName: "codex-gpt",
            rawModelID: "gpt-5.4",
            rawModelName: "gpt-5.4",
            rawModelVariant: nil
        )

        store.upsertProviderMapping(
            AgentUsageProviderDisplayMapping(identity: provider, displayProviderName: "OpenAI")
        )
        store.upsertModelMapping(
            AgentUsageModelDisplayMapping(
                identity: model,
                displayProviderName: "OpenAI",
                displayModelName: "gpt-5.4"
            )
        )

        let reloaded = AgentUsageMappingStore(
            persistence: UserDefaultsAgentUsageMappingPersistence(defaults: defaults)
        )

        XCTAssertEqual(reloaded.displayProviderName(for: provider), "OpenAI")
        XCTAssertEqual(reloaded.displayModelMapping(for: model)?.displayModelName, "gpt-5.4")
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMappingStoreTreatsCorruptPersistedDataAsEmpty() {
        let suiteName = "AgentUsageMappingStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("not-json".utf8), forKey: "agentUsageMappings")

        let store = AgentUsageMappingStore(
            persistence: UserDefaultsAgentUsageMappingPersistence(defaults: defaults)
        )
        let provider = AgentUsageProviderRawIdentity(
            source: .openCode,
            rawProviderID: "custom",
            rawProviderName: "custom"
        )

        XCTAssertNil(store.displayProviderName(for: provider))
        XCTAssertTrue(store.persistedMappings.providerMappings.isEmpty)
        XCTAssertTrue(store.persistedMappings.modelMappings.isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMappingStorePersistsReusableProviderAndModelNames() {
        let suiteName = "AgentUsageMappingStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AgentUsageMappingStore(
            persistence: UserDefaultsAgentUsageMappingPersistence(defaults: defaults)
        )

        store.addProviderDisplayName("OpenAI")
        store.addProviderDisplayName("Anthropic")
        store.addModelDisplayName("gpt-5.4")
        store.addModelDisplayName("claude-4")

        let reloaded = AgentUsageMappingStore(
            persistence: UserDefaultsAgentUsageMappingPersistence(defaults: defaults)
        )

        XCTAssertEqual(reloaded.providerDisplayNames, ["Anthropic", "OpenAI"])
        XCTAssertEqual(reloaded.modelDisplayNames, ["claude-4", "gpt-5.4"])
        defaults.removePersistentDomain(forName: suiteName)
    }
}
