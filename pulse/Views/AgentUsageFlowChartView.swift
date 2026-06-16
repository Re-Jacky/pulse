import SwiftUI
import Charts

struct AgentUsageFlowChartView: View {
    let dataPoints: [TokenUsageDataPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Token Trend")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            if let bucketSizeDays = bucketSizeDays, bucketSizeDays > 1 {
                Text("Each point combines \(bucketSizeDays) days.")
                    .font(.system(size: 10))
                    .foregroundColor(.appSecondaryText)
            }

            Chart(dataPoints) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.totalTokens)
                )
                .foregroundStyle(
                    LinearGradient(colors: [
                        Color.accentColor.opacity(0.3),
                        Color.accentColor.opacity(0.02)
                    ], startPoint: .top, endPoint: .bottom)
                )

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.totalTokens)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks(preset: .extended, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(Color.appDivider)
                    AxisValueLabel {
                        if let val = v.as(Int.self) {
                            Text(compact(val))
                                .font(.system(size: 9))
                                .foregroundColor(.appSecondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.month().day(), centered: true)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            .frame(height: 140)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bucketSizeDays: Int? {
        let sizes = Set(dataPoints.map(\.bucketSizeDays))
        return sizes.count == 1 ? sizes.first : nil
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
