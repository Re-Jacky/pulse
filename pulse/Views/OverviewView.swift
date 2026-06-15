import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var updateManager: UpdateManager
    @Environment(\.colorScheme) private var colorScheme
    private let versionInfo = AppVersionInfo()

    private var cpuFillColors: [Color] {
        if colorScheme == .light {
            return [Color(hex: "#2f855a"), Color(hex: "#38a169")]
        }

        return [Color(hex: "#60d394"), Color(hex: "#4ade80")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                MetricRowView(
                    label: "CPU",
                    value: String(format: "%.0f%%", monitor.cpuUsage),
                    subtext: "\(monitor.cpuCoreCount)-core · \(monitor.cpuChipName)",
                    percent: monitor.cpuUsage,
                    fillColors: cpuFillColors
                )

                MetricRowView(
                    label: "MEM",
                    value: String(format: "%.1f / %.0f GB", monitor.memUsedGB, monitor.memTotalGB),
                    subtext: String(format: "%.1f GB used", monitor.memUsedGB),
                    percent: monitor.memTotalGB > 0 ? (monitor.memUsedGB / monitor.memTotalGB) * 100 : 0,
                    fillColors: [Color(hex: "#60a5fa"), Color(hex: "#818cf8")]
                )

                MetricRowView(
                    label: "GPU",
                    value: monitor.gpuUsage >= 0 ? String(format: "%.0f%%", monitor.gpuUsage) : "N/A",
                    subtext: monitor.gpuCoreCount > 0 ? "\(monitor.gpuCoreCount)-core · \(monitor.gpuChipName)" : monitor.gpuChipName,
                    percent: monitor.gpuUsage,
                    fillColors: [Color(hex: "#f472b6"), Color(hex: "#e879f9")]
                )
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Divider()
                    .background(Color.appDivider)

                HStack(spacing: 4) {
                    Spacer(minLength: 0)

                    Text(versionInfo.appVersion ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.appPrimaryText)

                    updateStatusView

                    Spacer(minLength: 0)
                }

                Text(versionInfo.systemDisplayVersion)
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Checking...")
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
            }
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Downloading...")
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
            }
        case let .updateAvailable(release):
            Button("Update to \(release.version)") {
                Task { @MainActor in
                    do {
                        try await updateManager.downloadAvailableUpdate(release)
                    } catch {
                        updateManager.present(error: error)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.accentColor)
        case let .readyToInstall(release, _, _):
            Button("Install \(release.version)") {
                Task { @MainActor in
                    do {
                        try await updateManager.beginInstall()
                    } catch {
                        updateManager.present(error: error)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.accentColor)
        case let .failed(message):
            Button("Check again") {
                Task { @MainActor in
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.red)
            .help(message)
        case .upToDate:
            Text("Up to date")
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
        default:
            EmptyView()
        }
    }
}
