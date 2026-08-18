import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var agentUsageSettings: AgentUsageSettings
    @EnvironmentObject var agentLightsSettings: AgentLightsSettings
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    @EnvironmentObject var updateManager: UpdateManager
    @EnvironmentObject var launchAtLoginSettings: LaunchAtLoginSettings
    @State private var selectedSection: Section = .general
    private let versionInfo = AppVersionInfo()

    private enum Section: Hashable {
        case general
        case agentUsage
        case agentLights
        case updates
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appSecondaryText)

                sidebarButton(title: "General", systemImage: "gearshape", section: .general)
                sidebarButton(title: "Agent Usage", systemImage: "person.2.wave.2", section: .agentUsage)
                sidebarButton(title: "Agent Lights", systemImage: "dot.radiowaves.left.and.right", section: .agentLights)
                sidebarButton(title: "Updates", systemImage: "arrow.triangle.2.circlepath", section: .updates)

                Spacer()
            }
            .padding(16)
            .frame(width: 188, alignment: .topLeading)
            .background(Color.appSidebarBackground)

            Divider()

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        Group {
                            switch selectedSection {
                            case .general:
                                generalContent
                            case .agentUsage:
                                agentUsageContent
                            case .agentLights:
                                agentLightsContent
                            case .updates:
                                updateContent
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(spacing: 10) {
                    Divider()

                    VStack(spacing: 4) {
                        Text(versionInfo.appDisplayVersion)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)
                            .multilineTextAlignment(.center)

                        Text(versionInfo.systemDisplayVersion)
                            .font(.system(size: 12))
                            .foregroundColor(.appSecondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, minHeight: 280)
        .id(themeManager.currentTheme)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)

                Text("Start Pulse automatically when you log in to your Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = launchAtLoginSettings.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }

            Divider()

            Text("Theme")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Choose whether Pulse follows the system appearance or always uses a specific theme.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Theme", selection: $themeManager.currentTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }

    private var agentUsageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Usage")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Enable an optional agent usage analysis tab in the menu bar panel. Data loads on demand when a supported agent source is available.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable Agent Usage", isOn: $agentUsageSettings.isEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 10) {
                Text("Sources")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Text("Selected sources appear in the Agent tab and are included in totals. If none are selected, the Agent tab is hidden.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AgentSource.selectableCases) { source in
                    Toggle(source.displayName, isOn: sourceBinding(for: source))
                        .toggleStyle(.checkbox)
                }
            }
            .disabled(agentUsageSettings.isEnabled == false)
        }
    }

    private var agentLightsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Lights")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Show live agent session lights directly in the menu bar when Pulse-compatible plugin or hook integrations are installed.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable Agent Lights", isOn: $agentLightsSettings.isEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 10) {
                Text("Agents")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Text("Only selected agents show extra menu bar icon groups. Pulse keeps listening for live events, but hidden agents stay out of the menu bar.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AgentStatusAgent.allCases) { agent in
                    Toggle(agent.displayName, isOn: agentLightBinding(for: agent))
                        .toggleStyle(.checkbox)
                }
            }
            .disabled(agentLightsSettings.isEnabled == false)

            VStack(alignment: .leading, spacing: 8) {
                Text("Setup")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Text("Install the Pulse-compatible OpenCode plugin or Codex hook to send live events to Pulse. Agent Lights does not fall back to database, transcript, or log polling.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Use the Agent Lights menu bar panel to install or remove the OpenCode plugin and Codex hook.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Cleanup")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                HStack {
                    Button("Clear All OpenCode Slots") {
                        agentStatusStore.clearAllSlots(for: .openCode)
                    }

                    Button("Clear All Codex Slots") {
                        agentStatusStore.clearAllSlots(for: .codex)
                    }
                }
            }
        }
    }

    private var updateContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Updates")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text(versionInfo.appDisplayVersion)
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)

            switch updateManager.state {
            case .checking:
                ProgressView("Checking for updates...")
            case .downloading:
                ProgressView("Downloading update...")
            case let .updateAvailable(release):
                Button("Download Pulse \(release.version)") {
                    Task { @MainActor in
                        do {
                            try await updateManager.downloadAvailableUpdate(release)
                        } catch {
                            updateManager.present(error: error)
                        }
                    }
                }
            case let .readyToInstall(release, _, _):
                Button("Install Pulse \(release.version)") {
                    Task { @MainActor in
                        do {
                            try await updateManager.beginInstall()
                        } catch {
                            updateManager.present(error: error)
                        }
                    }
                }
            case let .failed(message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            default:
                Button("Check for Updates...") {
                    Task { @MainActor in
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                }
            }
        }
    }

    private func sidebarButton(title: String, systemImage: String, section: Section) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundColor(.appPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedSection == section ? Color.accentColor.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func sourceBinding(for source: AgentSource) -> Binding<Bool> {
        Binding(
            get: {
                agentUsageSettings.selectedSources.contains(source)
            },
            set: { isSelected in
                var next = agentUsageSettings.selectedSources
                if isSelected {
                    next.insert(source)
                } else {
                    next.remove(source)
                }
                agentUsageSettings.selectedSources = next
            }
        )
    }

    private func agentLightBinding(for agent: AgentStatusAgent) -> Binding<Bool> {
        Binding(
            get: {
                agentLightsSettings.selectedAgents.contains(agent)
            },
            set: { isSelected in
                var next = agentLightsSettings.selectedAgents
                if isSelected {
                    next.insert(agent)
                } else {
                    next.remove(agent)
                }
                agentLightsSettings.selectedAgents = next
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                launchAtLoginSettings.isEnabled
            },
            set: {
                launchAtLoginSettings.setEnabled($0)
            }
        )
    }
}
