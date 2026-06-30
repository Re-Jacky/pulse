import SwiftUI

private enum SessionManagementWindowLayout {
    static let defaultWidth: CGFloat = 1400
    static let defaultHeight: CGFloat = 1280
    static let minWidth: CGFloat = 1240
    static let minHeight: CGFloat = 720
    static let sidebarWidth: CGFloat = 360
    static let transcriptMinWidth: CGFloat = minWidth - sidebarWidth
    static let transcriptIdealWidth: CGFloat = defaultWidth - sidebarWidth
}

struct SessionManagementWindowView: View {
    @EnvironmentObject private var store: SessionManagementStore
    @EnvironmentObject private var sessionManagerThemeManager: SessionManagerThemeManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                switch store.sessionListState {
                case .failed(let message):
                    errorView(message: message)
                case .idle, .loading, .loaded:
                    HSplitView {
                        SessionListSidebarView()
                            .frame(
                                minWidth: SessionManagementWindowLayout.sidebarWidth,
                                idealWidth: SessionManagementWindowLayout.sidebarWidth,
                                maxWidth: SessionManagementWindowLayout.sidebarWidth,
                                maxHeight: .infinity
                            )

                        SessionTranscriptDetailView()
                            .frame(
                                minWidth: SessionManagementWindowLayout.transcriptMinWidth,
                                idealWidth: SessionManagementWindowLayout.transcriptIdealWidth,
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                            .layoutPriority(1)
                    }

                    if store.sessionListState == .idle || (store.sessionListState == .loading && store.sessions.isEmpty) {
                        loadingView
                            .background(Color(NSColor.windowBackgroundColor).opacity(0.82))
                    }
                }
            }
        }
        .frame(
            minWidth: SessionManagementWindowLayout.defaultWidth,
            minHeight: SessionManagementWindowLayout.minHeight
        )
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            DispatchQueue.main.async {
                store.refreshIfNeeded()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("Manage Sessions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Spacer(minLength: 12)

            Button {
                sessionManagerThemeManager.toggleTheme()
            } label: {
                Image(systemName: sessionManagerThemeManager.currentTheme == .dark ? "sun.max" : "moon.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundColor(.appSecondaryText)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.appDivider.opacity(0.6), lineWidth: 1)
            )
            .accessibilityLabel("Toggle Session Manager Theme")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading sessions...")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.appTertiaryText)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .multilineTextAlignment(.center)

            Button("Retry") {
                store.refresh()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
