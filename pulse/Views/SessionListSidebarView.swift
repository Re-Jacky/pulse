import SwiftUI

struct SessionListSidebarView: View {
    @EnvironmentObject private var store: SessionManagementStore
    @EnvironmentObject private var agentUsageSettings: AgentUsageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let enabledSources = agentUsageSettings.enabledSources
            let availableFilters = SessionManagerSourceFilter.allCases.filter { filter in
                switch filter {
                case .all: return enabledSources.count >= 2
                case .openCode: return enabledSources.contains(.openCode)
                case .codex: return enabledSources.contains(.codex)
                case .claudeCode: return enabledSources.contains(.claudeCode)
                }
            }

            if availableFilters.count >= 2 {
                Picker("Source", selection: sourceFilterBinding) {
                    ForEach(availableFilters) { source in
                        Text(sourceLabel(for: source)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
            }

            SearchableSelectorView(
                label: "Project",
                placeholder: "All Projects",
                selectedTitle: selectedProjectTitle,
                options: [
                    SearchableSelectorOption(
                        id: "__all__",
                        title: "All Projects",
                        subtitle: "Show every session in the current source"
                    )
                ] + store.projectOptions.map { option in
                    SearchableSelectorOption(
                        id: option.id,
                        title: option.title,
                        subtitle: option.id
                    )
                }
            ) { option in
                store.setSelectedProjectPath(option.id == "__all__" ? nil : option.id)
            }

            TextField("Search Sessions", text: searchQueryBinding)
                .textFieldStyle(.roundedBorder)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if visibleSessions.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(visibleSessions) { session in
                            Button {
                                store.selectSession(id: session.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.appPrimaryText)
                                        .lineLimit(2)

                                    Text(session.projectName)
                                        .font(.system(size: 11))
                                        .foregroundColor(.appSecondaryText)
                                        .lineLimit(1)

                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(SessionListRowFormatting.metadataSubtitleText(session.subtitle))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .layoutPriority(0)

                                        Text(SessionListRowFormatting.timestampText(updatedAt: session.updatedAt))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .layoutPriority(1)
                                    }
                                        .font(.system(size: 11))
                                        .foregroundColor(.appTertiaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(rowBackground(for: session))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(rowBorder(for: session), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appSidebarBackground)
    }

    private var selectedProjectTitle: String {
        guard let selectedProjectPath = store.selectedProjectPath else {
            return "All Projects"
        }

        return store.projectOptions.first(where: { $0.id == selectedProjectPath })?.title ?? "All Projects"
    }

    private var visibleSessions: [ManagedSessionSummary] {
        store.visibleSessions()
    }

    private var sourceFilterBinding: Binding<SessionManagerSourceFilter> {
        Binding(
            get: { store.selectedSourceFilter },
            set: { store.setSelectedSourceFilter($0) }
        )
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { store.searchQuery },
            set: { store.setSearchQuery($0) }
        )
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isLoadingSessions(for: store.selectedSourceFilter) {
                ProgressView()
                    .controlSize(.small)

                Text(loadingStateMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else {
                Text(emptyStateMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var loadingStateMessage: String {
        switch store.selectedSourceFilter {
        case .all:
            return "Loading sessions..."
        case .openCode:
            return "Loading OpenCode sessions..."
        case .codex:
            return "Loading Codex sessions..."
        case .claudeCode:
            return "Loading Claude sessions..."
        }
    }

    private var emptyStateMessage: String {
        if store.searchQuery.isEmpty == false {
            return "No sessions match the current search."
        }
        if store.selectedProjectPath != nil {
            return "No sessions match the current project."
        }

        switch store.selectedSourceFilter {
        case .all:
            return "No sessions found yet."
        case .openCode:
            return "No OpenCode sessions found."
        case .codex:
            return "No Codex sessions found."
        case .claudeCode:
            return "No Claude sessions found."
        }
    }

    private func sourceLabel(for source: SessionManagerSourceFilter) -> String {
        switch source {
        case .all:
            return "All"
        case .openCode:
            return "OpenCode"
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude"
        }
    }

    private func rowBackground(for session: ManagedSessionSummary) -> Color {
        guard store.selectedSessionID == session.id else {
            return Color.appFieldBackground.opacity(0.28)
        }

        return Color.accentColor.opacity(0.14)
    }

    private func rowBorder(for session: ManagedSessionSummary) -> Color {
        guard store.selectedSessionID == session.id else {
            return Color.appFieldBorder.opacity(0.18)
        }

        return Color.accentColor.opacity(0.28)
    }
}

enum SessionListRowFormatting {
    static func metadataSubtitleText(_ subtitle: String) -> String {
        "\(subtitle) •"
    }

    static func timestampText(
        updatedAt: Date,
        formatter: DateFormatter = shortDateTimeFormatter
    ) -> String {
        formatter.string(from: updatedAt)
    }

    static let shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
