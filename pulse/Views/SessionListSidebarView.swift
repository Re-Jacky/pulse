import SwiftUI

struct SessionListSidebarView: View {
    @EnvironmentObject private var store: SessionManagementStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $store.selectedSourceFilter) {
                ForEach(SessionManagerSourceFilter.allCases) { source in
                    Text(sourceLabel(for: source)).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Picker(
                "Project",
                selection: Binding(
                    get: { store.selectedProjectPath ?? "__all__" },
                    set: { store.selectedProjectPath = $0 == "__all__" ? nil : $0 }
                )
            ) {
                Text("All Projects").tag("__all__")
                ForEach(store.projectOptions) { option in
                    Text(option.title).tag(option.id)
                }
            }

            TextField("Search Sessions", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)

            List(
                store.visibleSessions(),
                selection: Binding(
                    get: { store.selectedSessionID },
                    set: { store.selectSession(id: $0) }
                )
            ) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.appPrimaryText)
                        .lineLimit(2)

                    Text(session.projectName)
                        .font(.system(size: 11))
                        .foregroundColor(.appSecondaryText)
                        .lineLimit(1)

                    Text(session.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.appTertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appSidebarBackground)
    }

    private func sourceLabel(for source: SessionManagerSourceFilter) -> String {
        switch source {
        case .all:
            return "All"
        case .openCode:
            return "OpenCode"
        case .codex:
            return "Codex"
        }
    }
}
