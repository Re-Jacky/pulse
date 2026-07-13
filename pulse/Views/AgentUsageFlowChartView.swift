import SwiftUI
import Charts

private enum AgentUsageChartMode: String, CaseIterable, Identifiable {
    case activity
    case trend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .trend: return "Trend"
        }
    }
}

struct AgentUsageFlowChartView: View {
    let trendDataPoints: [TokenUsageDataPoint]
    let activityDataPoints: [TokenUsageDataPoint]

    @AppStorage("agentUsageTokenChartMode") private var selectedModeRawValue = AgentUsageChartMode.activity.rawValue

    private var selectedMode: AgentUsageChartMode {
        AgentUsageChartMode(rawValue: selectedModeRawValue) ?? .activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Activity")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.appPrimaryText)

                    if selectedMode == .activity {
                        Text("Calendar year \(displayYear)")
                            .font(.system(size: 10))
                            .foregroundColor(.appSecondaryText)
                    }
                }

                Spacer()

                Picker("", selection: $selectedModeRawValue) {
                    ForEach(AgentUsageChartMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if selectedMode == .trend, let bucketSizeDays = trendBucketSizeDays, bucketSizeDays > 1 {
                Text("Each point combines \(bucketSizeDays) days.")
                    .font(.system(size: 10))
                    .foregroundColor(.appSecondaryText)
            }

            switch selectedMode {
            case .activity:
                AgentUsageActivityHotmapView(dataPoints: activityDataPoints)
            case .trend:
                AgentUsageTrendChartView(dataPoints: trendDataPoints)
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var displayYear: Int {
        AgentUsageActivityHotmapView.displayYear(for: activityDataPoints)
    }

    private var trendBucketSizeDays: Int? {
        let sizes = Set(trendDataPoints.map(\.bucketSizeDays))
        return sizes.count == 1 ? sizes.first : nil
    }
}

private struct AgentUsageActivityHotmapView: View {
    let dataPoints: [TokenUsageDataPoint]

    private static let displayCalendar = Calendar.autoupdatingCurrent
    private let calendar = Calendar.autoupdatingCurrent
    private let cellSize: CGFloat = 18
    private let cellSpacing: CGFloat = 4

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: cellSpacing) {
                    ForEach(weekColumns, id: \.self) { week in
                        Text(monthLabel(forWeek: week))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.appTertiaryText)
                            .lineLimit(1)
                            .frame(width: cellSize, alignment: .leading)
                    }
                }

                LazyHGrid(rows: rows, alignment: .top, spacing: cellSpacing) {
                    ForEach(calendarCells) { cell in
                        Text(cell.dayText)
                            .font(.system(size: 7, weight: cell.totalTokens > 0 ? .semibold : .regular))
                            .foregroundColor(textColor(for: cell))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .frame(width: cellSize, height: cellSize)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(color(for: cell.totalTokens, isInRange: cell.isInRange))
                            )
                            .help(helpText(for: cell))
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: (cellSize * 7) + (cellSpacing * 7) + 14)
    }

    static func displayYear(for dataPoints: [TokenUsageDataPoint], now: Date = Date()) -> Int {
        let currentYear = displayCalendar.component(.year, from: now)
        let activeYears = Set(dataPoints.map { displayCalendar.component(.year, from: $0.date) })
        if activeYears.contains(currentYear) || activeYears.isEmpty {
            return currentYear
        }
        return activeYears.max() ?? currentYear
    }

    private var rows: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
    }

    private var weekColumns: [Int] {
        Array(0..<(calendarCells.count / 7))
    }

    private var displayYear: Int {
        Self.displayYear(for: dataPoints)
    }

    private var maxTokens: Int {
        max(dataPoints.map(\.totalTokens).max() ?? 0, 1)
    }

    private var tokenByDay: [Int: Int] {
        Dictionary(uniqueKeysWithValues: dataPoints.map { point in
            (agentUsageDayIdentifier(for: point.date, calendar: calendar), point.totalTokens)
        })
    }

    private var yearStartDate: Date {
        calendar.date(from: DateComponents(year: displayYear, month: 1, day: 1)) ?? Date()
    }

    private var yearEndDate: Date {
        calendar.date(from: DateComponents(year: displayYear, month: 12, day: 31)) ?? yearStartDate
    }

    private var calendarCells: [ActivityCell] {
        let firstDay = agentUsageDayIdentifier(for: yearStartDate, calendar: calendar)
        let lastDay = agentUsageDayIdentifier(for: yearEndDate, calendar: calendar)
        let startDay = firstDay - weekdayIndex(for: yearStartDate)
        let dayCount = lastDay - startDay + 1
        let paddedCount = Int(ceil(Double(max(dayCount, 1)) / 7.0)) * 7

        return (0..<paddedCount).map { offset in
            let day = startDay + offset
            let date = date(forDayIdentifier: day)
            let isInRange = day >= firstDay && day <= lastDay
            return ActivityCell(
                day: day,
                date: date,
                totalTokens: isInRange ? tokenByDay[day, default: 0] : 0,
                isInRange: isInRange
            )
        }
    }

    private func monthLabel(forWeek week: Int) -> String {
        let startIndex = week * 7
        let endIndex = min(startIndex + 7, calendarCells.count)
        guard startIndex < endIndex else { return "" }
        let weekCells = calendarCells[startIndex..<endIndex]
        guard let firstInRange = weekCells.first(where: { $0.isInRange }) else { return "" }
        if week == 0 {
            return firstInRange.date.formatted(.dateTime.month(.abbreviated))
        }
        guard let firstDayOfMonth = weekCells.first(where: { cell in
            cell.isInRange && calendar.component(.day, from: cell.date) == 1
        }) else { return "" }
        return firstDayOfMonth.date.formatted(.dateTime.month(.abbreviated))
    }

    private func color(for tokens: Int, isInRange: Bool) -> Color {
        guard isInRange else { return Color.clear }
        guard tokens > 0 else { return Color.appFieldBorder.opacity(0.35) }

        let ratio = Double(tokens) / Double(maxTokens)
        switch ratio {
        case ..<0.25: return Color.accentColor.opacity(0.28)
        case ..<0.5: return Color.accentColor.opacity(0.45)
        case ..<0.75: return Color.accentColor.opacity(0.65)
        default: return Color.accentColor.opacity(0.9)
        }
    }

    private func textColor(for cell: ActivityCell) -> Color {
        guard cell.isInRange else { return Color.clear }
        return cell.totalTokens > 0 ? .appPrimaryText : .appTertiaryText
    }

    private func weekdayIndex(for date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private func date(forDayIdentifier day: Int) -> Date {
        dateForAgentUsageDayIdentifier(day)
    }

    private func helpText(for cell: ActivityCell) -> String {
        if cell.isInRange == false {
            return "Outside \(displayYear)"
        }
        return "\(compact(cell.totalTokens)) tokens on \(shortDate(cell.date))"
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private struct ActivityCell: Identifiable {
        let day: Int
        let date: Date
        let totalTokens: Int
        let isInRange: Bool

        var id: Int { day }

        var dayText: String {
            guard isInRange else { return "" }
            return "\(Calendar.autoupdatingCurrent.component(.day, from: date))"
        }
    }
}

private struct AgentUsageTrendChartView: View {
    let dataPoints: [TokenUsageDataPoint]

    var body: some View {
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

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
