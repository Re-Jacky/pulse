import SwiftUI

struct AgentUsageView: View {
    @EnvironmentObject private var agentStore: AgentUsageStore

    @AppStorage("agentUsageSelectedSource") private var selectedSourceRawValue = AgentSource.openCode.rawValue
    @AppStorage("agentUsageSelectedProjectDirectory") private var selectedProjectDirectory = ""
    @AppStorage("agentUsageSelectedSessionID") private var selectedSessionID = ""
    @AppStorage("agentUsageSelectedTimeRange") private var selectedTimeRangeRawValue = AgentTimeRange.allTime.rawValue
    @AppStorage("agentUsageModelGroupBy") private var modelGroupBy = "model"

    private var selectedSource: AgentSource {
        AgentSource(rawValue: selectedSourceRawValue) ?? .all
    }

    private var selectedProjectDirectoryValue: String? {
        selectedProjectDirectory.isEmpty ? nil : selectedProjectDirectory
    }

    private var selectedSessionIDValue: String? {
        selectedSessionID.isEmpty ? nil : selectedSessionID
    }

    private var selectedTimeRange: AgentTimeRange {
        AgentTimeRange(rawValue: selectedTimeRangeRawValue) ?? .allTime
    }

    private var scope: AgentScope {
        if let selectedProjectDirectoryValue, let selectedSessionIDValue, selectedSource != .all {
            return .session(projectDirectory: selectedProjectDirectory, sessionID: selectedSessionID)
        }
        if let selectedProjectDirectoryValue {
            return .project(directory: selectedProjectDirectory)
        }
        return .allProjects
    }

    private var isSessionScope: Bool {
        if case .session = scope { return true }
        return false
    }

    private var openCodeFilteredSnapshot: OpenCodeUsageSnapshot {
        agentStore.state.openCodeSnapshot.filtered(to: selectedTimeRange)
    }

    private var codexFilteredSnapshot: CodexUsageSnapshot {
        agentStore.state.codexSnapshot.filtered(to: selectedTimeRange)
    }

    private var summary: AgentUsageSummary {
        switch selectedSource {
        case .all:
            let oc = openCodeFilteredSnapshot.summary(for: scope)
            let cx = codexFilteredSnapshot.summary(for: scope)
            return AgentUsageSummary.merge(oc, cx)
        case .openCode: return openCodeFilteredSnapshot.summary(for: scope)
        case .codex: return codexFilteredSnapshot.summary(for: scope)
        }
    }

    private var tokenFlowData: [TokenUsageDataPoint] {
        guard selectedSource == .all, selectedTimeRange != .today else { return [] }

        let now = Date()
        let calendar = Calendar.current

        let minOC = openCodeFilteredSnapshot.sessions.min(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
        let minCX = codexFilteredSnapshot.sessions.min(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
        guard let earliest = [minOC, minCX].compactMap({ $0 }).min() else { return [] }

        let earliestDay = calendar.startOfDay(for: earliest)
        let nowDay = calendar.startOfDay(for: now)
        let totalDays = calendar.dateComponents([.day], from: earliestDay, to: nowDay).day.flatMap({ $0 > 0 ? $0 : 1 }) ?? 1
        let bucketSize: Int
        switch selectedTimeRange {
        case .allTime: bucketSize = max(1, Int(ceil(Double(totalDays) / 30)))
        default: bucketSize = 1
        }

        var entries: [(date: Date, tokens: Int)] = []
        for s in openCodeFilteredSnapshot.sessions {
            entries.append((calendar.startOfDay(for: s.updatedAt), s.totalTokens))
        }
        for s in codexFilteredSnapshot.sessions {
            entries.append((calendar.startOfDay(for: s.updatedAt), s.tokensUsed))
        }

        var buckets: [TokenUsageDataPoint] = []
        var cursor = earliestDay
        while cursor <= nowDay {
            guard let bucketEnd = calendar.date(byAdding: .day, value: bucketSize, to: cursor) else { break }
            let sum = entries
                .filter { $0.date >= cursor && $0.date < bucketEnd }
                .reduce(0) { $0 + $1.tokens }
            buckets.append(TokenUsageDataPoint(date: cursor, totalTokens: sum))
            cursor = bucketEnd
        }
        return buckets
    }

    private var projectOptions: [SearchableSelectorOption] {
        switch selectedSource {
        case .all:
            let ocProjects = Dictionary(grouping: openCodeFilteredSnapshot.sessions, by: \.directory)
            let cxProjects = Dictionary(grouping: codexFilteredSnapshot.sessions.filter { $0.isSubagent == false }, by: \.cwd)
            let allDirs = Set(ocProjects.keys).union(cxProjects.keys)
            return allDirs.map { dir -> SearchableSelectorOption in
                let ocSessions = ocProjects[dir] ?? []
                let cxSessions = cxProjects[dir] ?? []
                let totalTokens = ocSessions.reduce(0) { $0 + $1.totalTokens } + cxSessions.reduce(0) { $0 + $1.tokensUsed }
                let sessionsCount = ocSessions.count + cxSessions.count
                return SearchableSelectorOption(
                    id: dir,
                    title: URL(fileURLWithPath: dir).lastPathComponent,
                    subtitle: "\(compact(totalTokens)) total tokens \u{2022} \(sessionsCount) sessions \u{2022} \(dir)"
                )
            }
            .sorted { lhs, rhs in
                let lhsTokens = totalTokensForAllProject(lhs.id)
                let rhsTokens = totalTokensForAllProject(rhs.id)
                if lhsTokens == rhsTokens {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhsTokens > rhsTokens
            }
        case .openCode:
            return openCodeFilteredSnapshot.projectOptions.map {
                SearchableSelectorOption(
                    id: $0.directory,
                    title: $0.shortName,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
                )
            }
        case .codex:
            return codexFilteredSnapshot.projectOptions.map {
                SearchableSelectorOption(
                    id: $0.directory,
                    title: $0.shortName,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
                )
            }
        }
    }

    private func totalTokensForAllProject(_ dir: String) -> Int {
        let ocTokens = openCodeFilteredSnapshot.sessions.filter { $0.directory == dir }.reduce(0) { $0 + $1.totalTokens }
        let cxTokens = codexFilteredSnapshot.sessions.filter { $0.cwd == dir && $0.isSubagent == false }.reduce(0) { $0 + $1.tokensUsed }
        return ocTokens + cxTokens
    }

    private var sessionOptions: [SearchableSelectorOption] {
        switch selectedSource {
        case .all:
            return []
        case .openCode:
            guard let selectedProjectDirectoryValue else { return [] }
            return openCodeFilteredSnapshot.sessionOptions(for: selectedProjectDirectory).map {
                SearchableSelectorOption(
                    id: $0.id,
                    title: $0.title,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime($0.updatedAt)) \u{2022} \($0.modelDisplayName)"
                )
            }
        case .codex:
            guard let selectedProjectDirectoryValue else { return [] }
            return codexFilteredSnapshot.sessionOptions(for: selectedProjectDirectory).map {
                let effort = $0.reasoningEffort.isEmpty ? "" : " \u{2022} \($0.reasoningEffort)"
                return SearchableSelectorOption(
                    id: $0.id,
                    title: $0.title,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime($0.updatedAt)) \u{2022} \($0.modelDisplayName)\(effort)"
                )
            }
        }
    }

    private var selectedOpenCodeSession: OpenCodeSessionRecord? {
        guard selectedSource == .openCode, let selectedSessionIDValue else { return nil }
        return openCodeFilteredSnapshot.sessions.first(where: { $0.id == selectedSessionIDValue })
    }

    private var selectedCodexSession: CodexSessionRecord? {
        guard selectedSource == .codex, let selectedSessionIDValue else { return nil }
        return codexFilteredSnapshot.sessions.first(where: { $0.id == selectedSessionIDValue })
    }

    private var codexDetailState: CodexSessionDetailState {
        guard let selectedSessionIDValue else { return .idle }
        return agentStore.codexDetail(for: selectedSessionIDValue)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header

                if agentStore.isLoading {
                    ProgressView("Loading \(selectedSource.displayName) usage...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else if let error = agentStore.lastError {
                    errorState(error)
                } else {
                    timeRangeSelector
                    selectorsBlock
                    detailBlock

                    if selectedSource == .all && selectedTimeRange != .today && tokenFlowData.isEmpty == false {
                        AgentUsageFlowChartView(dataPoints: tokenFlowData)
                    }

                    if selectedSource != .all && isSessionScope == false {
                        byModelBlock
                    }

                    if selectedSource == .codex, isSessionScope, let session = selectedCodexSession {
                        CodexSessionDetailView(
                            session: session,
                            detailState: codexDetailState
                        )
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            agentStore.refreshIfNeeded()
            if selectedSource == .codex, let threadID = selectedSessionIDValue {
                agentStore.ensureCodexDetailLoaded(for: threadID)
            }
        }
        .onChange(of: selectedSessionID) { _ in
            if selectedSource == .codex, let threadID = selectedSessionIDValue {
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
                            selectedSource: selectedSource
                        ) { source in
                            selectedSourceRawValue = source.rawValue
                        }
                    } else {
                        Text(selectedSource.displayName)
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
                    agentStore.refreshAll()
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
        switch selectedSource {
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
                selectedTitle: selectedProjectDirectoryValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Projects",
                options: [
                    SearchableSelectorOption(
                        id: "__all__",
                        title: "All Projects",
                        subtitle: "Show all \(selectedSource.displayName) sessions"
                    )
                ] + projectOptions
            ) { option in
                if option.id == "__all__" {
                    selectedProjectDirectory = ""
                    selectedSessionID = ""
                } else {
                    selectedProjectDirectory = option.id
                    selectedSessionID = ""
                }
            }

            if selectedSource != .all && selectedProjectDirectoryValue != nil {
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
                    ] + sessionOptions
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

                if let input = summary.inputTokens {
                    metricCard(title: "Input", value: compact(input))
                }
                if let output = summary.outputTokens {
                    metricCard(title: "Output", value: compact(output))
                }
                if let cacheRead = summary.cacheReadTokens {
                    metricCard(title: "Cache Read", value: compact(cacheRead))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if let reasoning = summary.reasoningTokens {
                        summaryPill(title: "Reasoning", value: compact(reasoning))
                    }
                    if let cacheWrite = summary.cacheWriteTokens {
                        summaryPill(title: "Cache Write", value: compact(cacheWrite))
                    }
                    summaryPill(title: "Sessions", value: "\(summary.sessionsCount)")
                    summaryPill(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
                    if let cost = summary.cost, cost > 0 {
                        summaryPill(title: "Cost", value: String(format: "$%.2f", cost))
                    }
                }
            }

            if selectedSource != .all {
                Divider()
                    .background(Color.appDivider)

                Text("Context")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                switch selectedSource {
                case .all:
                    EmptyView()
                case .openCode:
                    openCodeContextRows
                case .codex:
                    codexContextRows
                }
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var openCodeContextRows: some View {
        Group {
            switch scope {
            case .allProjects:
                detailRow(title: "Projects Count", value: "\(openCodeFilteredSnapshot.projectOptions.count)")
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
            case .project(let directory):
                detailRow(title: "Project Name", value: URL(fileURLWithPath: directory).lastPathComponent)
                detailRow(title: "Full Path", value: directory)
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
            case .session:
                detailRow(title: "Title", value: selectedOpenCodeSession?.title ?? "-")
                detailRow(title: "Full Path", value: selectedOpenCodeSession?.directory ?? "-")
                detailRow(title: "Agent", value: selectedOpenCodeSession?.agent ?? "-")
                detailRow(
                    title: "Provider / Model",
                    value: selectedOpenCodeSession.map {
                        OpenCodeUsageSnapshot.modelDisplayName(
                            providerID: $0.modelProviderID,
                            modelID: $0.modelID,
                            variant: $0.modelVariant
                        )
                    } ?? "-"
                )
                detailRow(title: "Created", value: selectedOpenCodeSession.map { shortDateTime($0.createdAt) } ?? "-")
                detailRow(title: "Last Updated", value: selectedOpenCodeSession.map { shortDateTime($0.updatedAt) } ?? "-")
            }
        }
    }

    private var codexContextRows: some View {
        Group {
            switch scope {
            case .allProjects:
                detailRow(title: "Projects Count", value: "\(codexFilteredSnapshot.projectOptions.count)")
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
            case .project(let directory):
                detailRow(title: "Project Name", value: URL(fileURLWithPath: directory).lastPathComponent)
                detailRow(title: "Full Path", value: directory)
                detailRow(title: "Sessions Count", value: "\(summary.sessionsCount)")
                detailRow(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
            case .session:
                detailRow(title: "Title", value: selectedCodexSession?.title ?? "-")
                detailRow(title: "Full Path", value: selectedCodexSession?.cwd ?? "-")
                detailRow(title: "Model", value: selectedCodexSession.map { "\($0.modelProvider) / \($0.model)" } ?? "-")
                if let session = selectedCodexSession, session.reasoningEffort.isEmpty == false {
                    detailRow(title: "Reasoning Effort", value: session.reasoningEffort)
                }
                detailRow(title: "Created", value: selectedCodexSession.map { shortDateTime($0.createdAt) } ?? "-")
                detailRow(title: "Last Updated", value: selectedCodexSession.map { shortDateTime($0.updatedAt) } ?? "-")
            }
        }
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
                providerBreakdownView
            } else {
                modelBreakdownView
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var providerBreakdownView: some View {
        Group {
            switch selectedSource {
            case .all:
                EmptyView()
            case .openCode:
                let breakdown = openCodeFilteredSnapshot.providerBreakdown(for: scope)
                if breakdown.isEmpty {
                    Text("No provider usage data for this scope.")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                } else {
                    ForEach(breakdown) { provider in
                        detailRow(
                            title: provider.provider,
                            value: compact(provider.summary.totalTokens)
                        )
                    }
                }
            case .codex:
                let breakdown = codexFilteredSnapshot.providerBreakdown(for: scope)
                if breakdown.isEmpty {
                    Text("No provider usage data for this scope.")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                } else {
                    ForEach(breakdown) { provider in
                        detailRow(
                            title: provider.provider,
                            value: compact(provider.summary.totalTokens)
                        )
                    }
                }
            }
        }
    }

    private var modelBreakdownView: some View {
        Group {
            switch selectedSource {
            case .all:
                EmptyView()
            case .openCode:
                let breakdown = openCodeFilteredSnapshot.modelBreakdown(for: scope)
                if breakdown.isEmpty {
                    Text("No model usage data for this scope.")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                } else {
                    ForEach(breakdown) { model in
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
            case .codex:
                let breakdown = codexFilteredSnapshot.modelBreakdown(for: scope)
                if breakdown.isEmpty {
                    Text("No model usage data for this scope.")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                } else {
                    ForEach(breakdown) { model in
                        detailRow(
                            title: "\(model.modelProvider) / \(model.model)",
                            value: compact(model.summary.totalTokens)
                        )
                    }
                }
            }
        }
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
            Text("\(selectedSource.displayName) data unavailable")
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

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
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
