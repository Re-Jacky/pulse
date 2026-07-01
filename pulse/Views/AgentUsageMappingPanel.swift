import SwiftUI

struct AgentUsageMappingPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var mappingStore: AgentUsageMappingStore

    @State private var selectedGroupBy: AgentModelGroupBy
    @State private var providerDrafts: [String: String]
    @State private var modelProviderDrafts: [String: String]
    @State private var modelNameDrafts: [String: String]

    let providerCandidates: [AgentUsageProviderMappingCandidate]
    let modelCandidates: [AgentUsageModelMappingCandidate]

    init(
        selectedGroupBy: AgentModelGroupBy,
        providerCandidates: [AgentUsageProviderMappingCandidate],
        modelCandidates: [AgentUsageModelMappingCandidate],
        mappingStore: AgentUsageMappingStore
    ) {
        self._selectedGroupBy = State(initialValue: selectedGroupBy)
        self.providerCandidates = providerCandidates
        self.modelCandidates = modelCandidates
        self.mappingStore = mappingStore

        var providerDrafts: [String: String] = [:]
        for candidate in providerCandidates {
            providerDrafts[candidate.id] = mappingStore.displayProviderName(for: candidate.identity) ?? ""
        }
        _providerDrafts = State(initialValue: providerDrafts)

        var modelProviderDrafts: [String: String] = [:]
        var modelNameDrafts: [String: String] = [:]
        for candidate in modelCandidates {
            let mapping = mappingStore.displayModelMapping(for: candidate.identity)
            modelProviderDrafts[candidate.id] = mapping?.displayProviderName ?? ""
            modelNameDrafts[candidate.id] = mapping?.displayModelName ?? ""
        }
        _modelProviderDrafts = State(initialValue: modelProviderDrafts)
        _modelNameDrafts = State(initialValue: modelNameDrafts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All View Mapping")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.appPrimaryText)

                    Text("Create shared display names for raw provider and model identities in the combined Agent view.")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Picker(selection: $selectedGroupBy, label: EmptyView()) {
                Text("Provider").tag(AgentModelGroupBy.provider)
                Text("Model").tag(AgentModelGroupBy.model)
            }
            .pickerStyle(.segmented)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if selectedGroupBy == .provider {
                        providerSection
                    } else {
                        modelSection
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if providerCandidates.isEmpty {
                emptyState("No provider rows are available for the current combined view.")
            } else {
                ForEach(providerCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(candidate.identity.sourceQualifiedDisplayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.appPrimaryText)

                            Spacer()

                            Text(compact(candidate.totalTokens))
                                .font(.system(size: 11))
                                .foregroundColor(.appSecondaryText)
                        }

                        HStack(spacing: 8) {
                            TextField("Display provider name", text: providerBinding(for: candidate))
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                mappingStore.upsertProviderMapping(
                                    AgentUsageProviderDisplayMapping(
                                        identity: candidate.identity,
                                        displayProviderName: providerDrafts[candidate.id, default: ""]
                                    )
                                )
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reset") {
                                providerDrafts[candidate.id] = ""
                                mappingStore.resetProviderMapping(for: candidate.identity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .background(Color.appFieldBackground.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if modelCandidates.isEmpty {
                emptyState("No model rows are available for the current combined view.")
            } else {
                ForEach(modelCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(candidate.identity.sourceQualifiedDisplayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.appPrimaryText)

                            Spacer()

                            Text(compact(candidate.totalTokens))
                                .font(.system(size: 11))
                                .foregroundColor(.appSecondaryText)
                        }

                        HStack(spacing: 8) {
                            TextField("Display provider", text: modelProviderBinding(for: candidate))
                                .textFieldStyle(.roundedBorder)

                            TextField("Display model", text: modelNameBinding(for: candidate))
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                mappingStore.upsertModelMapping(
                                    AgentUsageModelDisplayMapping(
                                        identity: candidate.identity,
                                        displayProviderName: modelProviderDrafts[candidate.id, default: ""],
                                        displayModelName: modelNameDrafts[candidate.id, default: ""]
                                    )
                                )
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reset") {
                                modelProviderDrafts[candidate.id] = ""
                                modelNameDrafts[candidate.id] = ""
                                mappingStore.resetModelMapping(for: candidate.identity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .background(Color.appFieldBackground.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.appFieldBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func providerBinding(for candidate: AgentUsageProviderMappingCandidate) -> Binding<String> {
        Binding(
            get: { providerDrafts[candidate.id, default: ""] },
            set: { providerDrafts[candidate.id] = $0 }
        )
    }

    private func modelProviderBinding(for candidate: AgentUsageModelMappingCandidate) -> Binding<String> {
        Binding(
            get: { modelProviderDrafts[candidate.id, default: ""] },
            set: { modelProviderDrafts[candidate.id] = $0 }
        )
    }

    private func modelNameBinding(for candidate: AgentUsageModelMappingCandidate) -> Binding<String> {
        Binding(
            get: { modelNameDrafts[candidate.id, default: ""] },
            set: { modelNameDrafts[candidate.id] = $0 }
        )
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
