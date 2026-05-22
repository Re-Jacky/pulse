import SwiftUI

struct ProcessRowView: View {
    let process: ProcessInfo2
    let onKill: () -> Void

    private var cpuColor: Color {
        switch process.cpuPercent {
        case ..<5: return .white.opacity(0.6)
        case 5..<70: return Color(hex: "#60d394")
        case 70..<90: return Color(hex: "#f59e0b")
        default: return Color(hex: "#ef4444")
        }
    }

    private var memText: String {
        let mb = process.memoryMB
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private var pidText: String {
        let portStr = process.ports.isEmpty ? "" : " · :\(process.ports.first!)"
        return "PID \(process.id)\(portStr)"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pidText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.30))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f%%", process.cpuPercent))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(cpuColor)
                Text(memText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.38))
            }
            .frame(width: 60, alignment: .trailing)
        }
        .frame(height: 36)
        .padding(.horizontal, 4)
        .background(Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: onKill) {
                Label("Kill Process", systemImage: "xmark.circle")
            }
        }
    }
}
