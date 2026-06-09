import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var agentUsageSettings: AgentUsageSettings
    @State private var selectedSection: Section = .theme
    private let versionInfo = AppVersionInfo()

    private enum Section: Hashable {
        case theme
        case agentUsage
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appSecondaryText)

                sidebarButton(title: "Theme", systemImage: "circle.lefthalf.filled", section: .theme)
                sidebarButton(title: "Agent Usage", systemImage: "person.2.wave.2", section: .agentUsage)

                Spacer()
            }
            .padding(16)
            .frame(width: 188, alignment: .topLeading)
            .background(Color.appSidebarBackground)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Group {
                    switch selectedSection {
                    case .theme:
                        themeContent
                    case .agentUsage:
                        agentUsageContent
                    }
                }

                Spacer()

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
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, minHeight: 280)
        .id(themeManager.currentTheme)
    }

    private var themeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Theme")
                .font(.system(size: 22, weight: .semibold))
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
        }
        .buttonStyle(.plain)
    }
}
