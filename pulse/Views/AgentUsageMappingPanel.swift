import SwiftUI

struct AgentUsageMappingPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var mappingStore: AgentUsageMappingStore

    @State private var rowDrafts: [String: MappingDraft]
    @State private var isShowingNewProviderPrompt = false
    @State private var isShowingNewModelPrompt = false
    @State private var newProviderName = ""
    @State private var newModelName = ""

    private let rows: [AgentUsageMappingRow]

    init(
        providerCandidates: [AgentUsageProviderMappingCandidate],
        modelCandidates: [AgentUsageModelMappingCandidate],
        mappingStore: AgentUsageMappingStore
    ) {
        self.mappingStore = mappingStore

        var providerCandidatesByIdentity: [AgentUsageProviderRawIdentity: AgentUsageProviderMappingCandidate] = [:]
        for candidate in providerCandidates {
            providerCandidatesByIdentity[candidate.identity] = candidate
        }

        rows = modelCandidates.compactMap { model in
            let providerIdentity = AgentUsageProviderRawIdentity(
                source: model.identity.source,
                rawProviderID: model.identity.rawProviderID,
                rawProviderName: model.identity.rawProviderName
            )
            guard let provider = providerCandidatesByIdentity[providerIdentity] else { return nil }
            return AgentUsageMappingRow(providerCandidate: provider, modelCandidate: model)
        }

        var initialDrafts: [String: MappingDraft] = [:]
        for row in rows {
            let existingProvider = mappingStore.displayProviderName(for: row.providerCandidate.identity) ?? ""
            let existingModel = mappingStore.displayModelMapping(for: row.modelCandidate.identity)?.displayModelName ?? ""
            initialDrafts[row.id] = MappingDraft(
                providerDisplayName: existingProvider,
                modelDisplayName: existingModel
            )
        }
        _rowDrafts = State(initialValue: initialDrafts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actionBar

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    tableHeader

                    if rows.isEmpty {
                        emptyState("No combined provider/model rows are available for the current selection.")
                    } else {
                        ForEach(rows) { row in
                            mappingRow(row)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 980, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("New Provider Name", isPresented: $isShowingNewProviderPrompt) {
            TextField("Provider name", text: $newProviderName)
            Button("Cancel", role: .cancel) {
                newProviderName = ""
            }
            Button("Save") {
                let normalized = newProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
                mappingStore.addProviderDisplayName(normalized)
                if normalized.isEmpty == false {
                    applyProviderNameToEmptyDrafts(normalized)
                }
                newProviderName = ""
            }
        } message: {
            Text("Create a reusable provider display name for the mapping rows.")
        }
        .alert("New Model Name", isPresented: $isShowingNewModelPrompt) {
            TextField("Model name", text: $newModelName)
            Button("Cancel", role: .cancel) {
                newModelName = ""
            }
            Button("Save") {
                let normalized = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                mappingStore.addModelDisplayName(normalized)
                if normalized.isEmpty == false {
                    applyModelNameToEmptyDrafts(normalized)
                }
                newModelName = ""
            }
        } message: {
            Text("Create a reusable model display name for the mapping rows.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("All View Mapping")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Text("Map each raw source row to one saved provider name and one saved model name.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("New Provider Name") {
                newProviderName = ""
                isShowingNewProviderPrompt = true
            }
            .buttonStyle(.borderedProminent)

            Button("New Model Name") {
                newModelName = ""
                isShowingNewModelPrompt = true
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Text("\(rows.count) rows")
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            headerLabel("Raw Source", width: 320)
            headerLabel("Provider Mapping", width: 240)
            headerLabel("Model Mapping", width: 240)
            Spacer(minLength: 0)
        }
    }

    private func headerLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.appSecondaryText)
            .frame(width: width, alignment: .leading)
    }

    private func mappingRow(_ row: AgentUsageMappingRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.rawDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.appPrimaryText)
                Text(compact(row.totalTokens))
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
            }
            .frame(width: 320, alignment: .leading)

            providerPicker(for: row)
                .frame(width: 240)

            modelPicker(for: row)
                .frame(width: 240)

            Spacer(minLength: 0)

            Button("Save") {
                save(row: row)
            }
            .buttonStyle(.borderedProminent)

            Button("Reset") {
                reset(row: row)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func providerPicker(for row: AgentUsageMappingRow) -> some View {
        Picker("", selection: providerBinding(for: row)) {
            Text("Unmapped").tag("")
            ForEach(mappingStore.providerDisplayNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func modelPicker(for row: AgentUsageMappingRow) -> some View {
        Picker("", selection: modelBinding(for: row)) {
            Text("Unmapped").tag("")
            ForEach(mappingStore.modelDisplayNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
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

    private func providerBinding(for row: AgentUsageMappingRow) -> Binding<String> {
        Binding(
            get: { rowDrafts[row.id]?.providerDisplayName ?? "" },
            set: { value in
                var draft = rowDrafts[row.id] ?? MappingDraft(providerDisplayName: "", modelDisplayName: "")
                draft.providerDisplayName = value
                rowDrafts[row.id] = draft
            }
        )
    }

    private func modelBinding(for row: AgentUsageMappingRow) -> Binding<String> {
        Binding(
            get: { rowDrafts[row.id]?.modelDisplayName ?? "" },
            set: { value in
                var draft = rowDrafts[row.id] ?? MappingDraft(providerDisplayName: "", modelDisplayName: "")
                draft.modelDisplayName = value
                rowDrafts[row.id] = draft
            }
        )
    }

    private func save(row: AgentUsageMappingRow) {
        let draft = rowDrafts[row.id] ?? MappingDraft(providerDisplayName: "", modelDisplayName: "")
        if draft.providerDisplayName.isEmpty {
            mappingStore.resetProviderMapping(for: row.providerCandidate.identity)
        } else {
            mappingStore.upsertProviderMapping(
                AgentUsageProviderDisplayMapping(
                    identity: row.providerCandidate.identity,
                    displayProviderName: draft.providerDisplayName
                )
            )
        }

        if draft.providerDisplayName.isEmpty || draft.modelDisplayName.isEmpty {
            mappingStore.resetModelMapping(for: row.modelCandidate.identity)
        } else {
            mappingStore.upsertModelMapping(
                AgentUsageModelDisplayMapping(
                    identity: row.modelCandidate.identity,
                    displayProviderName: draft.providerDisplayName,
                    displayModelName: draft.modelDisplayName
                )
            )
        }
    }

    private func reset(row: AgentUsageMappingRow) {
        rowDrafts[row.id] = MappingDraft(providerDisplayName: "", modelDisplayName: "")
        mappingStore.resetProviderMapping(for: row.providerCandidate.identity)
        mappingStore.resetModelMapping(for: row.modelCandidate.identity)
    }

    private func applyProviderNameToEmptyDrafts(_ displayName: String) {
        for row in rows {
            guard var draft = rowDrafts[row.id], draft.providerDisplayName.isEmpty else { continue }
            draft.providerDisplayName = displayName
            rowDrafts[row.id] = draft
        }
    }

    private func applyModelNameToEmptyDrafts(_ displayName: String) {
        for row in rows {
            guard var draft = rowDrafts[row.id], draft.modelDisplayName.isEmpty else { continue }
            draft.modelDisplayName = displayName
            rowDrafts[row.id] = draft
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct AgentUsageMappingRow: Identifiable {
    let providerCandidate: AgentUsageProviderMappingCandidate
    let modelCandidate: AgentUsageModelMappingCandidate

    var id: String {
        providerCandidate.id + "::" + modelCandidate.id
    }

    var rawDisplayName: String {
        modelCandidate.identity.sourceQualifiedDisplayName
    }

    var totalTokens: Int {
        modelCandidate.totalTokens
    }
}

private struct MappingDraft {
    var providerDisplayName: String
    var modelDisplayName: String
}
