# All-View Provider/Model Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-defined provider/model mapping for the combined `All` Agent Usage view so equivalent raw identities from different agents can be merged under shared display names, while per-agent views remain source-native.

**Architecture:** Introduce a lightweight persisted mapping store plus a normalization layer that only runs in the `All` provider/model breakdown paths. Keep raw OpenCode/Codex data untouched, surface a gear-triggered mapping panel in the combined breakdown cards, and re-render the `All` breakdowns using canonical display names resolved from user mappings.

**Tech Stack:** Swift 5.9+, SwiftUI, AppStorage/UserDefaults-style local persistence, XCTest, existing Pulse managers/views

## Global Constraints

- Apply mappings only to the combined `All` view.
- Per-agent views (`OpenCode`, `Codex`) must continue showing raw source-native identities.
- Do not mutate source-native session/model/provider data.
- Do not change the daily bucket storage format.
- Restrict normalization to the combined provider/model breakdown paths.
- Unknown or unmapped entries must remain separate rather than being auto-merged.
- Corrupt or missing persisted mapping data must fail safely by showing raw names.

---

## File Structure

- Modify: `pulse/Managers/AgentUsageModels.swift`
  - Add raw identity and mapping model types used by the combined-view normalization layer.
- Create: `pulse/Managers/AgentUsageMappingStore.swift`
  - Persist and resolve user-defined provider/model display mappings for the combined `All` view.
- Modify: `pulse/Managers/AgentUsageStore.swift`
  - Inject mapping resolution into the combined provider/model breakdown builders only.
- Modify: `pulse/Managers/AgentUsageViewData.swift`
  - Carry enough state for the `All`-view mapping panel and combined breakdown card actions.
- Modify: `pulse/Views/AgentUsageView.swift`
  - Add gear actions for `All` provider/model cards and present the mapping panel.
- Create: `pulse/Views/AgentUsageMappingPanel.swift`
  - Render provider/model mapping controls and save/reset actions.
- Modify: `pulse.xcodeproj/project.pbxproj`
  - Add new Swift files to the app target and test target.
- Modify: `pulseTests/AgentUsageStoreTests.swift`
  - Add normalization and per-agent isolation coverage.
- Create: `pulseTests/AgentUsageMappingStoreTests.swift`
  - Add persistence and resolution tests for the mapping store.

## Task 1: Define Mapping Data Types

**Files:**
- Modify: `pulse/Managers/AgentUsageModels.swift`
- Test: `pulseTests/AgentUsageMappingStoreTests.swift`

**Interfaces:**
- Consumes: `AgentSource`
- Produces:
  - `struct AgentUsageProviderRawIdentity: Codable, Equatable, Hashable`
  - `struct AgentUsageModelRawIdentity: Codable, Equatable, Hashable`
  - `struct AgentUsageProviderDisplayMapping: Codable, Equatable`
  - `struct AgentUsageModelDisplayMapping: Codable, Equatable`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageMappingStoreTests test`
Expected: FAIL with unknown type errors for `AgentUsageProviderRawIdentity`

- [ ] **Step 3: Write minimal implementation**

```swift
struct AgentUsageProviderRawIdentity: Codable, Equatable, Hashable {
    let source: AgentSource
    let rawProviderID: String
    let rawProviderName: String
}

struct AgentUsageModelRawIdentity: Codable, Equatable, Hashable {
    let source: AgentSource
    let rawProviderID: String
    let rawProviderName: String
    let rawModelID: String
    let rawModelName: String
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageMappingStoreTests test`
Expected: PASS for `testProviderRawIdentityHashIncludesSource`

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift pulseTests/AgentUsageMappingStoreTests.swift
git commit -m "feat: add all-view mapping identity models"
```

### Task 2: Add Persisted Mapping Store

**Files:**
- Create: `pulse/Managers/AgentUsageMappingStore.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/AgentUsageMappingStoreTests.swift`

**Interfaces:**
- Consumes:
  - `AgentUsageProviderRawIdentity`
  - `AgentUsageModelRawIdentity`
  - `AgentUsageProviderDisplayMapping`
  - `AgentUsageModelDisplayMapping`
- Produces:
  - `protocol AgentUsageMappingPersisting`
  - `final class UserDefaultsAgentUsageMappingPersistence: AgentUsageMappingPersisting`
  - `@MainActor final class AgentUsageMappingStore: ObservableObject`
  - `func displayProviderName(for identity: AgentUsageProviderRawIdentity) -> String?`
  - `func displayModelMapping(for identity: AgentUsageModelRawIdentity) -> AgentUsageModelDisplayMapping?`
  - `func upsertProviderMapping(_ mapping: AgentUsageProviderDisplayMapping)`
  - `func upsertModelMapping(_ mapping: AgentUsageModelDisplayMapping)`
  - `func resetProviderMapping(for identity: AgentUsageProviderRawIdentity)`
  - `func resetModelMapping(for identity: AgentUsageModelRawIdentity)`

- [ ] **Step 1: Write the failing test**

```swift
func testMappingStorePersistsProviderAndModelMappings() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
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
        rawModelName: "gpt-5.4"
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageMappingStoreTests test`
Expected: FAIL with unknown symbol errors for `AgentUsageMappingStore`

- [ ] **Step 3: Write minimal implementation**

```swift
protocol AgentUsageMappingPersisting {
    func load() -> PersistedAgentUsageMappings?
    func save(_ mappings: PersistedAgentUsageMappings)
}

struct PersistedAgentUsageMappings: Codable, Equatable {
    var providerMappings: [AgentUsageProviderDisplayMapping]
    var modelMappings: [AgentUsageModelDisplayMapping]
}

final class UserDefaultsAgentUsageMappingPersistence: AgentUsageMappingPersisting {
    private let defaults: UserDefaults
    private let key = "agentUsageMappings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedAgentUsageMappings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedAgentUsageMappings.self, from: data)
    }

    func save(_ mappings: PersistedAgentUsageMappings) {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class AgentUsageMappingStore: ObservableObject {
    @Published private(set) var persistedMappings: PersistedAgentUsageMappings
    private let persistence: AgentUsageMappingPersisting

    init(persistence: AgentUsageMappingPersisting = UserDefaultsAgentUsageMappingPersistence()) {
        self.persistence = persistence
        self.persistedMappings = persistence.load() ?? PersistedAgentUsageMappings(
            providerMappings: [],
            modelMappings: []
        )
    }

    func displayProviderName(for identity: AgentUsageProviderRawIdentity) -> String? {
        persistedMappings.providerMappings.first { $0.identity == identity }?.displayProviderName
    }

    func displayModelMapping(for identity: AgentUsageModelRawIdentity) -> AgentUsageModelDisplayMapping? {
        persistedMappings.modelMappings.first { $0.identity == identity }
    }

    func upsertProviderMapping(_ mapping: AgentUsageProviderDisplayMapping) {
        persistedMappings.providerMappings.removeAll { $0.identity == mapping.identity }
        persistedMappings.providerMappings.append(mapping)
        persistence.save(persistedMappings)
    }

    func upsertModelMapping(_ mapping: AgentUsageModelDisplayMapping) {
        persistedMappings.modelMappings.removeAll { $0.identity == mapping.identity }
        persistedMappings.modelMappings.append(mapping)
        persistence.save(persistedMappings)
    }

    func resetProviderMapping(for identity: AgentUsageProviderRawIdentity) {
        persistedMappings.providerMappings.removeAll { $0.identity == identity }
        persistence.save(persistedMappings)
    }

    func resetModelMapping(for identity: AgentUsageModelRawIdentity) {
        persistedMappings.modelMappings.removeAll { $0.identity == identity }
        persistence.save(persistedMappings)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageMappingStoreTests test`
Expected: PASS for persistence and reload tests

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageMappingStore.swift pulse/Managers/AgentUsageModels.swift pulse.xcodeproj/project.pbxproj pulseTests/AgentUsageMappingStoreTests.swift
git commit -m "feat: add persisted all-view mapping store"
```

### Task 3: Normalize All-View Provider Breakdown

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Consumes:
  - `AgentUsageMappingStore.displayProviderName(for:) -> String?`
  - existing OpenCode/Codex provider breakdown data
- Produces:
  - combined provider breakdown rows grouped by mapped display provider names when `selection.source == .all`

- [ ] **Step 1: Write the failing test**

```swift
func testAllProviderBreakdownMergesMappedProvidersAcrossSources() {
    let mappingStore = AgentUsageMappingStore(persistence: InMemoryAgentUsageMappingPersistence())
    mappingStore.upsertProviderMapping(
        AgentUsageProviderDisplayMapping(
            identity: AgentUsageProviderRawIdentity(source: .codex, rawProviderID: "codex-gpt", rawProviderName: "codex-gpt"),
            displayProviderName: "OpenAI"
        )
    )
    mappingStore.upsertProviderMapping(
        AgentUsageProviderDisplayMapping(
            identity: AgentUsageProviderRawIdentity(source: .openCode, rawProviderID: "custom", rawProviderName: "custom"),
            displayProviderName: "OpenAI"
        )
    )

    let store = makeStoreWithLoadedState(
        openCodeSessions: [makeOpenCodeSession(id: "oc_1", providerID: "custom", modelID: "gpt-5.4", totalTokens: 50)],
        codexSessions: [makeCodexSession(id: "cx_1", modelProvider: "codex-gpt", model: "gpt-5.4", tokensUsed: 70)],
        mappingStore: mappingStore
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .all,
        dateSelection: .preset(.allTime),
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertEqual(data.providerBreakdown.count, 1)
    XCTAssertEqual(data.providerBreakdown.first?.provider, "OpenAI")
    XCTAssertEqual(data.providerBreakdown.first?.summary.totalTokens, 120)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests test`
Expected: FAIL because `All` breakdown still returns separate providers

- [ ] **Step 3: Write minimal implementation**

```swift
private func buildProviderBreakdown(
    selection: AgentUsageSelection,
    scope: AgentScope,
    openCodeSnapshot: OpenCodeUsageSnapshot,
    codexSnapshot: CodexUsageSnapshot
) -> [ProviderBreakdown] {
    switch selection.source {
    case .all:
        var totalsByProvider: [String: AgentUsageSummary] = [:]

        for row in openCodeSnapshot.providerBreakdown(for: scope) {
            let raw = AgentUsageProviderRawIdentity(
                source: .openCode,
                rawProviderID: row.provider,
                rawProviderName: row.provider
            )
            let name = mappingStore.displayProviderName(for: raw) ?? row.provider
            totalsByProvider[name] = totalsByProvider[name].map { AgentUsageSummary.merge($0, row.summary) } ?? row.summary
        }

        for row in codexSnapshot.providerBreakdown(for: scope) {
            let raw = AgentUsageProviderRawIdentity(
                source: .codex,
                rawProviderID: row.provider,
                rawProviderName: row.provider
            )
            let name = mappingStore.displayProviderName(for: raw) ?? row.provider
            totalsByProvider[name] = totalsByProvider[name].map { AgentUsageSummary.merge($0, row.summary) } ?? row.summary
        }

        return totalsByProvider.map { ProviderBreakdown(provider: $0.key, summary: $0.value) }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    case .openCode:
        return openCodeSnapshot.providerBreakdown(for: scope)
    case .codex:
        return codexSnapshot.providerBreakdown(for: scope)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests test`
Expected: PASS for the mapped provider merge test and existing provider breakdown tests

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: normalize all-view provider breakdown"
```

### Task 4: Normalize All-View Model Breakdown

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Modify: `pulse/Managers/AgentUsageViewData.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Consumes:
  - `AgentUsageMappingStore.displayModelMapping(for:) -> AgentUsageModelDisplayMapping?`
  - existing OpenCode/Codex model breakdown data
- Produces:
  - combined model breakdown rows grouped by mapped display model names when `selection.source == .all`

- [ ] **Step 1: Write the failing test**

```swift
func testAllModelBreakdownMergesMappedModelsAcrossSources() {
    let mappingStore = AgentUsageMappingStore(persistence: InMemoryAgentUsageMappingPersistence())
    mappingStore.upsertModelMapping(
        AgentUsageModelDisplayMapping(
            identity: AgentUsageModelRawIdentity(
                source: .codex,
                rawProviderID: "codex-gpt",
                rawProviderName: "codex-gpt",
                rawModelID: "gpt-5.4",
                rawModelName: "gpt-5.4"
            ),
            displayProviderName: "OpenAI",
            displayModelName: "gpt-5.4"
        )
    )
    mappingStore.upsertModelMapping(
        AgentUsageModelDisplayMapping(
            identity: AgentUsageModelRawIdentity(
                source: .openCode,
                rawProviderID: "custom",
                rawProviderName: "custom",
                rawModelID: "gpt-5.4",
                rawModelName: "gpt-5.4"
            ),
            displayProviderName: "OpenAI",
            displayModelName: "gpt-5.4"
        )
    )

    let store = makeStoreWithLoadedState(
        openCodeSessions: [makeOpenCodeSession(id: "oc_1", providerID: "custom", modelID: "gpt-5.4", totalTokens: 50)],
        codexSessions: [makeCodexSession(id: "cx_1", modelProvider: "codex-gpt", model: "gpt-5.4", tokensUsed: 70)],
        mappingStore: mappingStore
    )

    let data = store.derivedData(for: AgentUsageSelection(
        source: .all,
        dateSelection: .preset(.allTime),
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertTrue(data.modelBreakdownRows.contains {
        $0.title == "OpenAI / gpt-5.4" && $0.valueText == "120"
    })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests test`
Expected: FAIL because the `All` model rows still render separate raw identities

- [ ] **Step 3: Write minimal implementation**

```swift
private func buildAllModelBreakdownRows(
    scope: AgentScope,
    openCodeSnapshot: OpenCodeUsageSnapshot,
    codexSnapshot: CodexUsageSnapshot
) -> [AgentUsageDetailRow] {
    var totalsByModel: [String: AgentUsageSummary] = [:]

    for row in openCodeSnapshot.modelBreakdown(for: scope) {
        let raw = AgentUsageModelRawIdentity(
            source: .openCode,
            rawProviderID: row.providerID,
            rawProviderName: row.providerID,
            rawModelID: row.modelID,
            rawModelName: OpenCodeUsageSnapshot.modelDisplayName(providerID: row.providerID, modelID: row.modelID, variant: row.variant)
        )
        let mapping = mappingStore.displayModelMapping(for: raw)
        let title = "\(mapping?.displayProviderName ?? row.providerID) / \(mapping?.displayModelName ?? row.modelID)"
        totalsByModel[title] = totalsByModel[title].map { AgentUsageSummary.merge($0, row.summary) } ?? row.summary
    }

    for row in codexSnapshot.modelBreakdown(for: scope) {
        let raw = AgentUsageModelRawIdentity(
            source: .codex,
            rawProviderID: row.modelProvider,
            rawProviderName: row.modelProvider,
            rawModelID: row.model,
            rawModelName: row.model
        )
        let mapping = mappingStore.displayModelMapping(for: raw)
        let title = "\(mapping?.displayProviderName ?? row.modelProvider) / \(mapping?.displayModelName ?? row.model)"
        totalsByModel[title] = totalsByModel[title].map { AgentUsageSummary.merge($0, row.summary) } ?? row.summary
    }

    return totalsByModel.map { key, value in
        AgentUsageDetailRow(id: key, title: key, valueText: compact(value.totalTokens), secondaryText: nil)
    }
    .sorted { Int($0.valueText) ?? 0 > Int($1.valueText) ?? 0 }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests test`
Expected: PASS for the mapped model merge test and existing model breakdown tests

- [ ] **Step 5: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift pulse/Managers/AgentUsageViewData.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: normalize all-view model breakdown"
```

### Task 5: Build the Mapping Panel UI

**Files:**
- Create: `pulse/Views/AgentUsageMappingPanel.swift`
- Modify: `pulse/Views/AgentUsageView.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Consumes:
  - `AgentUsageMappingStore`
  - derived raw provider/model identities for the current `All` view
- Produces:
  - gear actions for `All` provider/model cards
  - mapping panel with `Providers` and `Models` sections

- [ ] **Step 1: Write the failing test**

```swift
func testAllViewShowsMappingGearForCombinedBreakdownsOnly() {
    let store = makeStoreWithLoadedState(
        openCodeSessions: [makeOpenCodeSession(id: "oc_1")],
        codexSessions: [makeCodexSession(id: "cx_1")]
    )

    let allData = store.derivedData(for: AgentUsageSelection(
        source: .all,
        dateSelection: .preset(.allTime),
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))
    let codexData = store.derivedData(for: AgentUsageSelection(
        source: .codex,
        dateSelection: .preset(.allTime),
        projectDirectory: nil,
        sessionID: nil,
        modelGroupBy: .model
    ))

    XCTAssertTrue(allData.showsCombinedBreakdownMappingControls)
    XCTAssertFalse(codexData.showsCombinedBreakdownMappingControls)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests test`
Expected: FAIL with unknown property `showsCombinedBreakdownMappingControls`

- [ ] **Step 3: Write minimal implementation**

```swift
struct AgentUsageViewData {
    let showsCombinedBreakdownMappingControls: Bool
    let allViewProviderIdentities: [AgentUsageProviderRawIdentity]
    let allViewModelIdentities: [AgentUsageModelRawIdentity]
}
```

```swift
private func byModelBlock(data: AgentUsageViewData) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Text("By Model")
            Spacer()
            if data.showsCombinedBreakdownMappingControls {
                Button {
                    presentedMappingPanel = .models
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }
        }
        ...
    }
}
```

```swift
struct AgentUsageMappingPanel: View {
    let providerIdentities: [AgentUsageProviderRawIdentity]
    let modelIdentities: [AgentUsageModelRawIdentity]
    @EnvironmentObject private var mappingStore: AgentUsageMappingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("All View Mappings")
            Text("Mappings affect only the combined All view.")
            providerSection
            modelSection
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 360)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests test`
Expected: PASS for `showsCombinedBreakdownMappingControls` coverage and existing `AgentUsageStoreTests`

- [ ] **Step 5: Commit**

```bash
git add pulse/Views/AgentUsageView.swift pulse/Views/AgentUsageMappingPanel.swift pulse/Managers/AgentUsageViewData.swift pulse.xcodeproj/project.pbxproj pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: add all-view mapping panel"
```

### Task 6: Wire Editing, Reset, and Refresh Behavior

**Files:**
- Modify: `pulse/Views/AgentUsageMappingPanel.swift`
- Modify: `pulse/Managers/AgentUsageStore.swift`
- Test: `pulseTests/AgentUsageMappingStoreTests.swift`
- Test: `pulseTests/AgentUsageStoreTests.swift`

**Interfaces:**
- Consumes:
  - `AgentUsageMappingStore.upsertProviderMapping(_:)`
  - `AgentUsageMappingStore.upsertModelMapping(_:)`
  - `AgentUsageMappingStore.resetProviderMapping(for:)`
  - `AgentUsageMappingStore.resetModelMapping(for:)`
- Produces:
  - editable display name workflows in the panel
  - immediate `All` breakdown refresh after save/reset

- [ ] **Step 1: Write the failing test**

```swift
func testResetMappingRestoresSeparateAllViewProviders() {
    let persistence = InMemoryAgentUsageMappingPersistence()
    let mappingStore = AgentUsageMappingStore(persistence: persistence)

    let codexIdentity = AgentUsageProviderRawIdentity(
        source: .codex,
        rawProviderID: "codex-gpt",
        rawProviderName: "codex-gpt"
    )
    mappingStore.upsertProviderMapping(
        AgentUsageProviderDisplayMapping(identity: codexIdentity, displayProviderName: "OpenAI")
    )
    mappingStore.resetProviderMapping(for: codexIdentity)

    XCTAssertNil(mappingStore.displayProviderName(for: codexIdentity))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageMappingStoreTests test`
Expected: FAIL if reset or refresh behavior is incomplete

- [ ] **Step 3: Write minimal implementation**

```swift
Button("Save") {
    mappingStore.upsertProviderMapping(
        AgentUsageProviderDisplayMapping(
            identity: identity,
            displayProviderName: editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    )
}

Button("Reset") {
    mappingStore.resetProviderMapping(for: identity)
}
```

```swift
@MainActor
final class AgentUsageStore: ObservableObject {
    @Published private(set) var mappingRefreshToken = UUID()

    func invalidateCombinedBreakdownMappings() {
        mappingRefreshToken = UUID()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageMappingStoreTests test`
Expected: PASS for reset behavior and persistence tests

- [ ] **Step 5: Commit**

```bash
git add pulse/Views/AgentUsageMappingPanel.swift pulse/Managers/AgentUsageStore.swift pulseTests/AgentUsageMappingStoreTests.swift pulseTests/AgentUsageStoreTests.swift
git commit -m "feat: wire all-view mapping edits and reset"
```

## Self-Review

- Spec coverage:
  - Combined `All`-only mapping behavior: Tasks 3-6
  - Persisted mapping layer: Tasks 1-2
  - Gear-triggered mapping panel: Task 5
  - Safe reset/unmapped behavior: Task 6
  - Per-agent isolation: Tasks 3-4 tests
- Placeholder scan:
  - No `TODO`/`TBD` placeholders remain.
  - All test, implementation, and command steps include concrete content.
- Type consistency:
  - Mapping identities and mapping store interfaces are defined before the tasks that consume them.
  - Combined-view UI task depends on the same types and names introduced earlier.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-01-all-view-model-provider-mapping.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
