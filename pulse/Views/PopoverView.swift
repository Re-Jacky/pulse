import SwiftUI

struct PopoverView: View {
    @AppStorage("selectedTab") private var selectedTab = 0
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var agentUsageSettings: AgentUsageSettings
    @EnvironmentObject var agentStore: AgentUsageStore
    @EnvironmentObject var updateManager: UpdateManager
    private let versionInfo = AppVersionInfo()

    private var availableTabs: [(title: String, tag: Int)] {
        var tabs: [(String, Int)] = [("Processes", 0)]
        if agentUsageSettings.effectiveEnabled {
            tabs.append(("Agent", 1))
        }
        return tabs
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Picker("", selection: $selectedTab) {
                        ForEach(availableTabs, id: \.tag) { tab in
                            Text(tab.title).tag(tab.tag)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Spacer()
                        ProductVersionHeaderView(versionInfo: versionInfo)
                            .environmentObject(updateManager)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .background(Color.appDivider)

                ZStack {
                    ProcessListView()
                        .opacity(selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 0)

                    if agentUsageSettings.effectiveEnabled {
                        AgentUsageView()
                            .opacity(selectedTab == 1 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: agentUsageSettings.effectiveEnabled ? 460 : 280, minHeight: 360)
        .id(themeManager.currentTheme)
        .onChange(of: agentUsageSettings.effectiveEnabled) { isEnabled in
            if isEnabled == false && selectedTab == 1 {
                selectedTab = 0
            }
            syncPanelTabSelection()
            refreshAgentUsageIfVisible()
        }
        .onChange(of: selectedTab) { _ in
            syncPanelTabSelection()
            refreshAgentUsageIfVisible()
        }
        .onAppear {
            if agentUsageSettings.effectiveEnabled == false && selectedTab == 1 {
                selectedTab = 0
            }
            syncPanelTabSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulsePanelDidOpen)) { _ in
            refreshAgentUsageIfVisible()
        }
    }

    private func syncPanelTabSelection() {
        NotificationCenter.default.post(name: .pulsePanelTabDidChange, object: selectedTab)
    }

    private func refreshAgentUsageIfVisible() {
        guard agentUsageSettings.effectiveEnabled, selectedTab == 1 else { return }
        agentStore.refreshAllAsync()
    }
}

private struct ProductVersionHeaderView: View {
    let versionInfo: AppVersionInfo

    @EnvironmentObject var updateManager: UpdateManager

    var body: some View {
        HStack(spacing: 6) {
            if case .downloading = updateManager.state {
            } else {
                Text(versionInfo.headerDisplayVersion)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.appSecondaryText)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            updateStatusView
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pulse \(versionInfo.headerDisplayVersion), \(accessibilityStatus)")
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                Text("Checking")
                    .font(.system(size: 10))
            }
            .foregroundColor(.appSecondaryText)
        case .downloading:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                Text("Downloading")
                    .font(.system(size: 10))
            }
            .foregroundColor(.appSecondaryText)
        case let .updateAvailable(release):
            Button("Update") {
                Task { @MainActor in
                    do {
                        try await updateManager.downloadAvailableUpdate(release)
                    } catch {
                        updateManager.present(error: error)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .help("Update to Pulse \(release.version)")
        case let .readyToInstall(release, _, _):
            Button("Install") {
                Task { @MainActor in
                    do {
                        try await updateManager.beginInstall()
                    } catch {
                        updateManager.present(error: error)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .help("Install Pulse \(release.version)")
        case let .failed(message):
            Button("Retry") {
                Task { @MainActor in
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.red)
            .help(message)
        default:
            EmptyView()
        }
    }

    private var accessibilityStatus: String {
        switch updateManager.state {
        case .checking:
            return "checking for updates"
        case .downloading:
            return "downloading update"
        case let .updateAvailable(release):
            return "update \(release.version) available"
        case let .readyToInstall(release, _, _):
            return "update \(release.version) ready to install"
        case .failed:
            return "update check failed"
        case .upToDate:
            return "up to date"
        default:
            return "update status idle"
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
