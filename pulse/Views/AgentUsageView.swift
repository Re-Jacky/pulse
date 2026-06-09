import SwiftUI

struct AgentUsageView: View {
    @EnvironmentObject private var usageStore: OpenCodeUsageStore

    @AppStorage("agentUsageSelectedProjectDirectory") private var selectedProjectDirectory = ""
    @AppStorage("agentUsageSelectedSessionID") private var selectedSessionID = ""
    @AppStorage("agentUsageSelectedTimeRange") private var selectedTimeRangeRawValue = OpenCodeTimeRange.allTime.rawValue

    private var isSessionScope: Bool {
        selectedProjectDirectoryValue != nil && selectedSessionIDValue != nil
    }

    private var scope: OpenCodeScope {
        if let selectedProjectDirectoryValue, let selectedSessionIDValue {
            return .session(projectDirectory: selectedProjectDirectory, sessionID: selectedSessionID)
        }
        if let selectedProjectDirectoryValue {
            return .project(directory: selectedProjectDirectory)
        }
        return .allProjects
    }

    private var selectedProjectDirectoryValue: String? {
        selectedProjectDirectory.isEmpty ? nil : selectedProjectDirectory
    }

    private var selectedSessionIDValue: String? {
        selectedSessionID.isEmpty ? nil : selectedSessionID
    }

    private var summary: OpenCodeUsageSummary {
        filteredSnapshot.summary(for: scope)
    }

    private var projectOptions: [OpenCodeProjectOption] {
        filteredSnapshot.projectOptions
    }

    private var sessionOptions: [OpenCodeSessionOption] {
        guard let selectedProjectDirectoryValue else { return [] }
        return filteredSnapshot.sessionOptions(for: selectedProjectDirectory)
    }

    private var selectedSession: OpenCodeSessionRecord? {
        guard let selectedSessionIDValue else { return nil }
        return filteredSnapshot.sessions.first(where: { $0.id == selectedSessionID })
    }

    private var selectedTimeRange: OpenCodeTimeRange {
        OpenCodeTimeRange(rawValue: selectedTimeRangeRawValue) ?? .allTime
    }

    private var filteredSnapshot: OpenCodeUsageSnapshot {
        usageStore.snapshot.filtered(to: selectedTimeRange)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header

                if usageStore.isLoading {
                    ProgressView("Loading OpenCode usage...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else if let error = usageStore.lastError {
                    errorState(error)
                } else {
                    timeRangeSelector
                    selectorsBlock
                    detailBlock

                    if isSessionScope == false {
                        byModelBlock
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            usageStore.refreshIfNeeded()
        }
        .onChange(of: usageStore.snapshot) { _ in
            reconcileSelection()
        }
        .onChange(of: selectedTimeRangeRawValue) { _ in
            reconcileSelection()
        }
    }

    private var timeRangeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Range")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Picker("Range", selection: $selectedTimeRangeRawValue) {
                ForEach(OpenCodeTimeRange.allCases) { range in
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

                    Text("OpenCode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.appPrimaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appFieldBackground)
                        .clipShape(Capsule())
                }

                Spacer()

                Button(usageStore.isRefreshing ? "Refreshing..." : "Refresh") {
                    usageStore.refresh()
                }
                .buttonStyle(.borderless)
                .disabled(usageStore.isRefreshing)
            }

            Text("Pulse reads this agent's local usage data from \(usageStore.databaseURL.path) when you refresh the panel.")
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
                .textSelection(.enabled)
        }
    }

    private var selectorsBlock: some View {
        VStack(spacing: 12) {
            SearchableSelectorView(
                label: "Project",
                placeholder: "All Projects",
                selectedTitle: selectedProjectDirectoryValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Projects",
                options: [
                    SearchableSelectorOption(
                        id: "__all__",
                        title: "All Projects",
                        subtitle: "Show all OpenCode sessions"
                    )
                ] + projectOptions.map {
                    SearchableSelectorOption(
                        id: $0.directory,
                        title: $0.shortName,
                        subtitle: "\(compact($0.summary.totalTokens)) total tokens • \($0.summary.sessionsCount) sessions • \($0.directory)"
                    )
                }
            ) { option in
                if option.id == "__all__" {
                    selectedProjectDirectory = ""
                    selectedSessionID = ""
                } else {
                    selectedProjectDirectory = option.id
                    selectedSessionID = ""
                }
            }

            if selectedProjectDirectoryValue != nil {
                SearchableSelectorView(
                    label: "Session",
                    placeholder: "All Sessions",
                    selectedTitle: sessionOptions.first(where: { $0.id == selectedSessionIDValue })?.title ?? "All Sessions",
                    options: [
                        SearchableSelectorOption(
                            id: "__all__",
                            title: "All Sessions",
                            subtitle: "Show the full project summary"
                        )
                    ] + sessionOptions.map {
                        SearchableSelectorOption(
                            id: $0.id,
                            title: $0.title,
                            subtitle: "\(compact($0.summary.totalTokens)) total tokens • \(shortDateTime($0.updatedAt)) • \($0.modelDisplayName)"
                        )
                    }
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
                metricCard(title: "Total", value: compact(summary.totalTokens))
                metricCard(title: "Input", value: compact(summary.inputTokens))
                metricCard(title: "Output", value: compact(summary.outputTokens))
                metricCard(title: "Cache Read", value: compact(summary.cacheReadTokens))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    summaryPill(title: "Reasoning", value: compact(summary.reasoningTokens))
                    summaryPill(title: "Cache Write", value: compact(summary.cacheWriteTokens))
                    summaryPill(title: "Sessions", value: "\(summary.sessionsCount)")
                    summaryPill(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
                    if summary.cost > 0 {
                        summaryPill(title: "Cost", value: String(format: "$%.2f", summary.cost))
                    }
                }
            }

            Divider()
                .background(Color.appDivider)

            Text("Context")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            switch scope {
            case .allProjects:
                detailRow(title: "Projects Count", value: "\(projectOptions.count)")
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
            case .project(let directory):
                detailRow(title: "Project Name", value: URL(fileURLWithPath: directory).lastPathComponent)
                detailRow(title: "Full Path", value: directory)
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
            case .session:
                detailRow(title: "Title", value: selectedSession?.title ?? "-")
                detailRow(title: "Full Path", value: selectedSession?.directory ?? "-")
                detailRow(title: "Agent", value: selectedSession?.agent ?? "-")
                detailRow(
                    title: "Provider / Model",
                    value: selectedSession.map {
                        OpenCodeUsageSnapshot.modelDisplayName(
                            providerID: $0.modelProviderID,
                            modelID: $0.modelID,
                            variant: $0.modelVariant
                        )
                    } ?? "-"
                )
                detailRow(title: "Created", value: selectedSession.map(shortDateTime) ?? "-")
                detailRow(title: "Last Updated", value: selectedSession.map { shortDateTime($0.updatedAt) } ?? "-")
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var byModelBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            if filteredSnapshot.modelBreakdown(for: scope).isEmpty {
                Text("No model usage data for this scope.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else {
                ForEach(filteredSnapshot.modelBreakdown(for: scope)) { model in
                    detailRow(
                        title: OpenCodeUsageSnapshot.modelDisplayName(
                            providerID: model.providerID,
                            modelID: model.modelID,
                            variant: model.variant
                        ),
                        value: compact(model.summary.totalTokens)
                    )
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

    private func errorState(_ error: OpenCodeUsageStore.LoadError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenCode data unavailable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)

            Text("Expected DB: \(usageStore.databaseURL.path)")
                .font(.system(size: 11))
                .foregroundColor(.appTertiaryText)
                .textSelection(.enabled)

            Button("Refresh") {
                usageStore.refresh()
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

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func shortDateTime(_ session: OpenCodeSessionRecord) -> String {
        shortDateTime(session.updatedAt)
    }

    private func reconcileSelection() {
        if let selectedProjectDirectoryValue,
           projectOptions.contains(where: { $0.directory == selectedProjectDirectory }) == false {
            selectedProjectDirectory = ""
            selectedSessionID = ""
            return
        }

        if let selectedProjectDirectoryValue, let selectedSessionIDValue {
            let validSessionIDs = Set(sessionOptions.map(\.id))
            if validSessionIDs.contains(selectedSessionID) == false {
                selectedProjectDirectory = selectedProjectDirectoryValue
                selectedSessionID = ""
            }
        }
    }
}
