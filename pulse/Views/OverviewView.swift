import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MetricRowView(
                label: "CPU",
                value: String(format: "%.0f%%", monitor.cpuUsage),
                subtext: "\(monitor.cpuCoreCount)-core · \(monitor.cpuChipName)",
                percent: monitor.cpuUsage,
                fillColors: [Color(hex: "#60d394"), Color(hex: "#4ade80")]
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
        .padding(16)
    }
}
