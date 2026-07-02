import SwiftUI

struct AgentUsageMappingPanel: View {
    @ObservedObject var mappingStore: AgentUsageMappingStore

    @State private var rowDrafts: [String: MappingDraft]
    @State private var isShowingNewProviderPrompt = false
    @State private var isShowingNewModelPrompt = false
    @State private var newProviderName = ""
    @State private var newModelName = ""
    @State private var rowFilter = AgentUsageMappingRowFilter.all

    private let rows: [AgentUsageMappingRow]

    private var filteredRows: [AgentUsageMappingRow] {
        rows.filter { row in
            switch rowFilter {
            case .all:
                return true
            case .mapped:
                return isRowMapped(row)
            case .unmapped:
                return isRowMapped(row) == false
            }
        }
    }

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
                    } else if filteredRows.isEmpty {
                        emptyState("No \(rowFilter.title.lowercased()) rows match the current filter.")
                    } else {
                        ForEach(filteredRows) { row in
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
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Picker("Filter", selection: $rowFilter) {
                    ForEach(AgentUsageMappingRowFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)

                Text("\(filteredRows.count) of \(rows.count) rows")
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
            }

            savedNamesSection(
                title: "Saved Provider Names",
                names: mappingStore.providerDisplayNames,
                emptyMessage: "No saved provider names yet.",
                remove: removeProviderDisplayName
            )

            savedNamesSection(
                title: "Saved Model Names",
                names: mappingStore.modelDisplayNames,
                emptyMessage: "No saved model names yet.",
                remove: removeModelDisplayName
            )
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            headerLabel("Raw Source")
                .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            headerLabel("Provider Mapping")
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            headerLabel("Model Mapping")
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            headerLabel("Actions")
                .frame(width: 150, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func headerLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.appSecondaryText)
    }

    private func mappingRow(_ row: AgentUsageMappingRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.rawDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.appPrimaryText)
                    .lineLimit(2)
                Text(compact(row.totalTokens))
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)

            providerPicker(for: row)
                .frame(minWidth: 180, maxWidth: .infinity)
                .layoutPriority(1)

            modelPicker(for: row)
                .frame(minWidth: 180, maxWidth: .infinity)
                .layoutPriority(1)

            actionButtons(for: row)
                .frame(width: 150, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actionButtons(for row: AgentUsageMappingRow) -> some View {
        HStack(spacing: 8) {
            Button(isRowMapped(row) ? "Update" : "Save") {
                save(row: row)
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 74)

            Button("Reset") {
                reset(row: row)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 68)
        }
    }

    private func providerPicker(for row: AgentUsageMappingRow) -> some View {
        SearchableDropdown(
            options: mappingStore.providerDisplayNames,
            selection: providerBinding(for: row),
            placeholder: "Unmapped"
        )
    }

    private func modelPicker(for row: AgentUsageMappingRow) -> some View {
        SearchableDropdown(
            options: mappingStore.modelDisplayNames,
            selection: modelBinding(for: row),
            placeholder: "Unmapped"
        )
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

    private func savedNamesSection(
        title: String,
        names: [String],
        emptyMessage: String,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            if names.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.appTertiaryText)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(names, id: \.self) { name in
                        savedNameChip(name: name) {
                            remove(name)
                        }
                    }
                }
            }
        }
    }

    private func savedNameChip(name: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.appPrimaryText)

            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Delete \(name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.appFieldBackground)
        .clipShape(Capsule())
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

    private func removeProviderDisplayName(_ displayName: String) {
        mappingStore.removeProviderDisplayName(displayName)
        for row in rows {
            guard var draft = rowDrafts[row.id], draft.providerDisplayName == displayName else { continue }
            draft.providerDisplayName = ""
            rowDrafts[row.id] = draft
        }
    }

    private func isRowMapped(_ row: AgentUsageMappingRow) -> Bool {
        mappingStore.displayProviderName(for: row.providerCandidate.identity)?.isEmpty == false
            && mappingStore.displayModelMapping(for: row.modelCandidate.identity)?.displayModelName.isEmpty == false
    }

    private func removeModelDisplayName(_ displayName: String) {
        mappingStore.removeModelDisplayName(displayName)
        for row in rows {
            guard var draft = rowDrafts[row.id], draft.modelDisplayName == displayName else { continue }
            draft.modelDisplayName = ""
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

private struct SearchableDropdown: View {
    let options: [String]
    @Binding var selection: String
    var placeholder: String = "Unmapped"

    @State private var isExpanded = false
    @State private var searchText = ""

    private var filteredOptions: [String] {
        if searchText.isEmpty { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection.isEmpty ? placeholder : selection)
                    .font(.system(size: 12))
                    .foregroundColor(selection.isEmpty ? .appTertiaryText : .appPrimaryText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.appSecondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                searchText = selection
                isExpanded.toggle()
            }

            if isExpanded {
                Divider()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.appTertiaryText)
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredOptions, id: \.self) { option in
                            Text(option)
                                .font(.system(size: 12))
                                .foregroundColor(.appPrimaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(option == selection ? Color.accentColor.opacity(0.12) : Color.clear)
                                .onTapGesture {
                                    selection = option
                                    isExpanded = false
                                }
                            if option != filteredOptions.last {
                                Divider()
                                    .padding(.leading, 8)
                            }
                        }

                        if filteredOptions.isEmpty {
                            Text("No matches")
                                .font(.system(size: 11))
                                .foregroundColor(.appTertiaryText)
                                .padding(8)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .background(Color.appFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isExpanded ? Color.accentColor : Color.appSecondaryText.opacity(0.25), lineWidth: 1)
        )
        .onChange(of: isExpanded) { expanded in
            if !expanded {
                searchText = ""
            }
        }
    }
}

private enum AgentUsageMappingRowFilter: String, CaseIterable, Identifiable {
    case all
    case mapped
    case unmapped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .mapped: return "Mapped"
        case .unmapped: return "Unmapped"
        }
    }
}
