import SwiftUI

struct AgentUsageView: View {
    @EnvironmentObject private var agentStore: AgentUsageStore

    @AppStorage("agentUsageSelectedSource") private var selectedSourceRawValue = AgentSource.openCode.rawValue
    @AppStorage("agentUsageSelectedProjectDirectory") private var selectedProjectDirectory = ""
    @AppStorage("agentUsageSelectedSessionID") private var selectedSessionID = ""
    @AppStorage("agentUsageSelectedTimeRange") private var selectedTimeRangeRawValue = AgentTimeRange.allTime.rawValue
    @AppStorage("agentUsageModelGroupBy") private var modelGroupBy = "model"

    private var selection: AgentUsageSelection {
        AgentUsageSelection(
            source: AgentSource(rawValue: selectedSourceRawValue) ?? .all,
            timeRange: AgentTimeRange(rawValue: selectedTimeRangeRawValue) ?? .allTime,
            projectDirectory: selectedProjectDirectory.isEmpty ? nil : selectedProjectDirectory,
            sessionID: selectedSessionID.isEmpty ? nil : selectedSessionID,
            modelGroupBy: AgentModelGroupBy(rawValue: modelGroupBy) ?? .model
        )
    }

    private var data: AgentUsageDerivedViewData {
        agentStore.derivedData(for: selection)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header

                if agentStore.isLoading {
                    ProgressView("Loading \(data.selection.source.displayName) usage...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else if let error = agentStore.lastError {
                    errorState(error)
                } else {
                    timeRangeSelector
                    selectorsBlock
                    detailBlock

                    if data.showsTokenFlow && data.tokenFlowData.isEmpty == false {
                        AgentUsageFlowChartView(dataPoints: data.tokenFlowData)
                    }

                    if data.showsByModel {
                        byModelBlock
                    }

                    if let threadID = data.codexDetailThreadID,
                       let session = data.selectedCodexSession {
                        CodexSessionDetailView(
                            session: session,
                            detailState: agentStore.codexDetail(for: threadID)
                        )
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            if let threadID = data.codexDetailThreadID {
                agentStore.ensureCodexDetailLoaded(for: threadID)
            }
        }
        .onChange(of: selectedSessionID) { _ in
            if let threadID = data.codexDetailThreadID {
                agentStore.ensureCodexDetailLoaded(for: threadID)
            }
        }
    }

    private var timeRangeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Range")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Picker("Range", selection: $selectedTimeRangeRawValue) {
                ForEach(AgentTimeRange.allCases) { range in
                    Text(range.label).tag(range.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Text("Agent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.appSecondaryText)

                    if agentStore.availableSources.count > 1 {
                        AgentSourcePicker(
                            availableSources: agentStore.availableSources,
                            selectedSource: selection.source
                        ) { source in
                            selectedSourceRawValue = source.rawValue
                        }
                    } else {
                        Text(selection.source.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.appFieldBackground)
                            .clipShape(Capsule())
                    }
                }

                Spacer()

                Button(agentStore.isRefreshing ? "Refreshing..." : "Refresh") {
                    agentStore.refreshAllAsync()
                }
                .buttonStyle(.borderless)
                .disabled(agentStore.isRefreshing)
            }

            Text("Pulse reads this agent\u{2019}s local usage data from \(databasePath) when you refresh the panel.")
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
                .textSelection(.enabled)
        }
    }

    private var databasePath: String {
        switch selection.source {
        case .all:
            let paths = [agentStore.repository.openCodeDatabaseURL.path, agentStore.repository.codexDatabaseURL?.path].compactMap { $0 }
            return paths.joined(separator: " + ")
        case .openCode: return agentStore.repository.openCodeDatabaseURL.path
        case .codex: return agentStore.repository.codexDatabaseURL?.path ?? "Codex database not found"
        }
    }

    private var selectorsBlock: some View {
        VStack(spacing: 12) {
            SearchableSelectorView(
                label: "Project",
                placeholder: "All Projects",
                selectedTitle: selection.projectDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Projects",
                options: [
                    SearchableSelectorOption(
                        id: "__all__",
                        title: "All Projects",
                        subtitle: "Show all \(selection.source.displayName) sessions"
                    )
                ] + data.projectOptions
            ) { option in
                if option.id == "__all__" {
                    selectedProjectDirectory = ""
                    selectedSessionID = ""
                } else {
                    selectedProjectDirectory = option.id
                    selectedSessionID = ""
                }
            }

            if selection.source != .all && selection.projectDirectory != nil {
                SearchableSelectorView(
                    label: "Session",
                    placeholder: "All Sessions",
                    selectedTitle: data.sessionOptions.first(where: { $0.id == selection.sessionID })?.title ?? "All Sessions",
                    options: [
                        SearchableSelectorOption(
                            id: "__all__",
                            title: "All Sessions",
                            subtitle: "Show the full project summary"
                        )
                    ] + data.sessionOptions
                ) { option in
                    selectedSessionID = option.id == "__all__" ? "" : option.id
                }
            }
        }
    }

    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(data.usageMetrics) { metric in
                    metricCard(title: metric.title, value: metric.valueText)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(data.summaryPills) { pill in
                        summaryPill(title: pill.title, value: pill.valueText)
                    }
                }
            }

            if selection.source != .all {
                Divider()
                    .background(Color.appDivider)

                Text("Context")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                ForEach(data.contextRows) { row in
                    detailRow(title: row.title, value: row.valueText)
                }
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var byModelBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("By")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Picker(selection: $modelGroupBy, label: EmptyView()) {
                    Text("Provider").tag("provider")
                    Text("Model").tag("model")
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Spacer()
            }

            if modelGroupBy == "provider" {
                ForEach(data.providerBreakdown) { provider in
                    detailRow(title: provider.provider, value: compact(provider.summary.totalTokens))
                }
            } else {
                ForEach(data.modelBreakdownRows) { row in
                    detailRow(title: row.title, value: row.valueText)
                }
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.appPrimaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.appPrimaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorState(_ error: AgentUsageStore.LoadError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(selection.source.displayName) data unavailable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)

            Text("Expected DB: \(databasePath)")
                .font(.system(size: 11))
                .foregroundColor(.appTertiaryText)
                .textSelection(.enabled)

            Button("Refresh") {
                agentStore.refreshAll()
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundColor(.appSecondaryText)

            Spacer(minLength: 8)

            Text(value)
                .foregroundColor(.appPrimaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

struct TokenUsageDataPoint: Identifiable {
    let date: Date
    let totalTokens: Int
    var id: Date { date }
}

struct ProviderBreakdown: Identifiable {
    let provider: String
    let summary: AgentUsageSummary
    var id: String { provider }
}
