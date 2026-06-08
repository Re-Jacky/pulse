import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedSection: Section = .theme
    private let versionInfo = AppVersionInfo()

    private enum Section: Hashable {
        case theme
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appSecondaryText)

                Button {
                    selectedSection = .theme
                } label: {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 12))
                        Text("Theme")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(selectedSection == .theme ? Color.accentColor.opacity(0.14) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(16)
            .frame(width: 140, alignment: .topLeading)
            .background(Color.appSidebarBackground)

            Divider()

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
}
