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

enum AgentUsageActivityCalendarScope: String, CaseIterable, Identifiable {
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: return "Month"
        case .year: return "Year"
        }
    }
}

struct AgentUsageActivityDisplayMonth: Equatable {
    let year: Int
    let month: Int
}

struct AgentUsageActivityCalendarCell: Identifiable {
    let day: Int
    let date: Date
    let isInDisplayedMonth: Bool
    let isInDisplayedYear: Bool

    var id: Int { day }
}

enum AgentUsageActivityColorPalette {
    enum Level: Equatable {
        case none
        case lowest
        case low
        case mediumLow
        case medium
        case mediumHigh
        case high
        case highest
    }

    static let activeLevels: [Level] = [.lowest, .low, .mediumLow, .medium, .mediumHigh, .high, .highest]

    static func level(for tokens: Int, maxTokens: Int) -> Level {
        guard tokens > 0 else { return .none }

        let ratio = Double(tokens) / Double(max(maxTokens, 1))
        switch ratio {
        case ..<0.15: return .lowest
        case ..<0.30: return .low
        case ..<0.45: return .mediumLow
        case ..<0.60: return .medium
        case ..<0.75: return .mediumHigh
        case ..<0.90: return .high
        default: return .highest
        }
    }

    static func fillColor(for level: Level, colorScheme: ColorScheme) -> Color {
        guard let hex = fillHex(for: level, colorScheme: colorScheme) else {
            return Color.appFieldBorder.opacity(0.35)
        }
        return Color(hex: hex)
    }

    static func fillHex(for level: Level, colorScheme: ColorScheme) -> String? {
        switch (colorScheme, level) {
        case (_, .none): return nil
        case (.light, .lowest): return "#E0F7F4"
        case (.light, .low): return "#BDEDE7"
        case (.light, .mediumLow): return "#8ADBD3"
        case (.light, .medium): return "#55C8C2"
        case (.light, .mediumHigh): return "#24AAA8"
        case (.light, .high): return "#087F8C"
        case (.light, .highest): return "#065F73"
        case (.dark, .lowest): return "#203A52"
        case (.dark, .low): return "#2D4968"
        case (.dark, .mediumLow): return "#3A5D7B"
        case (.dark, .medium): return "#497092"
        case (.dark, .mediumHigh): return "#648BAA"
        case (.dark, .high): return "#91C5DD"
        case (.dark, .highest): return "#D6F4FF"
        @unknown default: return "#32B7AF"
        }
    }

    static func textColor(for level: Level, colorScheme: ColorScheme) -> Color {
        switch (colorScheme, level) {
        case (_, .none):
            return .appTertiaryText
        case (.light, .high), (.light, .highest):
            return Color.white.opacity(0.95)
        case (.dark, .high), (.dark, .highest):
            return Color(hex: "#101214")
        default:
            return .appPrimaryText
        }
    }
}

enum AgentUsageActivityCalendarLayout {
    static func month(
        byAdding value: Int,
        to month: AgentUsageActivityDisplayMonth,
        calendar: Calendar = .autoupdatingCurrent
    ) -> AgentUsageActivityDisplayMonth {
        let currentDate = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) ?? Date()
        let updatedDate = calendar.date(byAdding: .month, value: value, to: currentDate) ?? currentDate
        return AgentUsageActivityDisplayMonth(
            year: calendar.component(.year, from: updatedDate),
            month: calendar.component(.month, from: updatedDate)
        )
    }

    static func yearMonths(
        for year: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [AgentUsageActivityDisplayMonth] {
        (1...12).map { month in
            AgentUsageActivityDisplayMonth(year: year, month: month)
        }
    }

    static func weekdayLabels(calendar: Calendar = .autoupdatingCurrent) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let startIndex = max(calendar.firstWeekday - 1, 0)
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }

    static func displayMonth(
        for dataPoints: [TokenUsageDataPoint],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> AgentUsageActivityDisplayMonth {
        currentDisplayMonth(now: now, calendar: calendar)
    }

    static func displayYear(
        for dataPoints: [TokenUsageDataPoint],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        currentDisplayYear(now: now, calendar: calendar)
    }

    static func currentDisplayMonth(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> AgentUsageActivityDisplayMonth {
        AgentUsageActivityDisplayMonth(
            year: calendar.component(.year, from: now),
            month: calendar.component(.month, from: now)
        )
    }

    static func currentDisplayYear(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        calendar.component(.year, from: now)
    }

    static func monthCells(
        for month: AgentUsageActivityDisplayMonth,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [AgentUsageActivityCalendarCell] {
        guard let monthStart = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart),
              let monthEnd = calendar.date(from: DateComponents(year: month.year, month: month.month, day: dayRange.count)) else {
            return []
        }

        return cells(
            startDate: monthStart,
            endDate: monthEnd,
            calendar: calendar,
            isInDisplayedMonth: { date in
                calendar.component(.year, from: date) == month.year &&
                calendar.component(.month, from: date) == month.month
            },
            isInDisplayedYear: { date in
                calendar.component(.year, from: date) == month.year
            }
        )
    }

    static func filteredDataPoints(
        _ dataPoints: [TokenUsageDataPoint],
        scope: AgentUsageActivityCalendarScope,
        displayMonth: AgentUsageActivityDisplayMonth,
        displayYear: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TokenUsageDataPoint] {
        dataPoints.filter { point in
            switch scope {
            case .month:
                return calendar.component(.year, from: point.date) == displayMonth.year &&
                    calendar.component(.month, from: point.date) == displayMonth.month
            case .year:
                return calendar.component(.year, from: point.date) == displayYear
            }
        }
    }

    private static func cells(
        startDate: Date,
        endDate: Date,
        calendar: Calendar,
        isInDisplayedMonth: (Date) -> Bool,
        isInDisplayedYear: (Date) -> Bool
    ) -> [AgentUsageActivityCalendarCell] {
        let firstDay = agentUsageDayIdentifier(for: startDate, calendar: calendar)
        let lastDay = agentUsageDayIdentifier(for: endDate, calendar: calendar)
        let startDay = firstDay - weekdayIndex(for: startDate, calendar: calendar)
        let dayCount = lastDay - startDay + 1
        let paddedCount = Int(ceil(Double(max(dayCount, 1)) / 7.0)) * 7

        return (0..<paddedCount).map { offset in
            let day = startDay + offset
            let date = dateForAgentUsageDayIdentifier(day, calendar: calendar)
            return AgentUsageActivityCalendarCell(
                day: day,
                date: date,
                isInDisplayedMonth: isInDisplayedMonth(date),
                isInDisplayedYear: isInDisplayedYear(date)
            )
        }
    }

    static func weekdayIndex(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

struct AgentUsageFlowChartView: View {
    let trendDataPoints: [TokenUsageDataPoint]
    let activityDataPoints: [TokenUsageDataPoint]

    @AppStorage("agentUsageTokenChartMode") private var selectedModeRawValue = AgentUsageChartMode.activity.rawValue
    @AppStorage("agentUsageActivityCalendarScope") private var selectedScopeRawValue = AgentUsageActivityCalendarScope.month.rawValue
    @State private var selectedDisplayMonth: AgentUsageActivityDisplayMonth?
    @State private var selectedDisplayYear: Int?

    private let calendar = Calendar.autoupdatingCurrent

    private var selectedMode: AgentUsageChartMode {
        AgentUsageChartMode(rawValue: selectedModeRawValue) ?? .activity
    }

    private var selectedScope: AgentUsageActivityCalendarScope {
        AgentUsageActivityCalendarScope(rawValue: selectedScopeRawValue) ?? .month
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Activity")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.appPrimaryText)

                    Text(activitySubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.appSecondaryText)
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

            rangeControls

            switch selectedMode {
            case .activity:
                AgentUsageActivityHotmapView(
                    dataPoints: activityDataPoints,
                    selectedScope: selectedScope,
                    displayMonth: displayMonth,
                    displayYear: displayYear,
                    calendar: calendar
                ) { month in
                    selectedDisplayMonth = month
                    selectedScopeRawValue = AgentUsageActivityCalendarScope.month.rawValue
                }
            case .trend:
                AgentUsageTrendChartView(dataPoints: selectedTrendDataPoints)
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rangeControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    moveBackward()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help(selectedScope == .month ? "Previous month" : "Previous year")

                Text(selectedScope == .month ? monthTitle : "Calendar year \(displayYear)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.appSecondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Button {
                    moveForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help(selectedScope == .month ? "Next month" : "Next year")
            }

            Button {
                jumpToCurrentPeriod()
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(selectedScope == .month ? "Jump to current month" : "Jump to current year")

            Spacer()

            Menu {
                ForEach(AgentUsageActivityCalendarScope.allCases) { scope in
                    Button {
                        selectedScopeRawValue = scope.rawValue
                    } label: {
                        Label(
                            scope.title,
                            systemImage: selectedScope == scope ? "checkmark" : "calendar"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(selectedScope.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.appSecondaryText)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 88)
            .help("Switch token activity scope")
        }
    }

    private var activitySubtitle: String {
        selectedScope == .month ? "\(monthTitle) range" : "\(displayYear) range"
    }

    private var displayYear: Int {
        selectedDisplayYear ?? AgentUsageActivityCalendarLayout.displayYear(for: activityDataPoints, calendar: calendar)
    }

    private var displayMonth: AgentUsageActivityDisplayMonth {
        selectedDisplayMonth ?? AgentUsageActivityCalendarLayout.displayMonth(for: activityDataPoints, calendar: calendar)
    }

    private var monthTitle: String {
        let date = calendar.date(from: DateComponents(year: displayMonth.year, month: displayMonth.month, day: 1)) ?? Date()
        return date.formatted(.dateTime.month(.wide).year())
    }

    private var selectedTrendDataPoints: [TokenUsageDataPoint] {
        AgentUsageActivityCalendarLayout.filteredDataPoints(
            activityDataPoints.isEmpty ? trendDataPoints : activityDataPoints,
            scope: selectedScope,
            displayMonth: displayMonth,
            displayYear: displayYear,
            calendar: calendar
        )
    }

    private func moveBackward() {
        switch selectedScope {
        case .month:
            selectedDisplayMonth = AgentUsageActivityCalendarLayout.month(byAdding: -1, to: displayMonth, calendar: calendar)
        case .year:
            selectedDisplayYear = displayYear - 1
        }
    }

    private func moveForward() {
        switch selectedScope {
        case .month:
            selectedDisplayMonth = AgentUsageActivityCalendarLayout.month(byAdding: 1, to: displayMonth, calendar: calendar)
        case .year:
            selectedDisplayYear = displayYear + 1
        }
    }

    private func jumpToCurrentPeriod() {
        selectedDisplayMonth = AgentUsageActivityCalendarLayout.currentDisplayMonth(calendar: calendar)
        selectedDisplayYear = AgentUsageActivityCalendarLayout.currentDisplayYear(calendar: calendar)
    }
}

private struct AgentUsageActivityHotmapView: View {
    let dataPoints: [TokenUsageDataPoint]
    let selectedScope: AgentUsageActivityCalendarScope
    let displayMonth: AgentUsageActivityDisplayMonth
    let displayYear: Int
    let calendar: Calendar
    let onSelectMonth: (AgentUsageActivityDisplayMonth) -> Void

    @State private var hoverSummary: AgentUsageActivityHoverSummary?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentUsageActivityHoverSummaryView(summary: hoverSummary)

            switch selectedScope {
            case .month:
                AgentUsageActivityMonthView(
                    cells: monthCells,
                    tokenByDay: tokenByDay,
                    maxTokens: maxTokens,
                    calendar: calendar,
                    onHoverSummaryChange: { hoverSummary = $0 }
                )
            case .year:
                AgentUsageActivityYearView(
                    months: yearMonths,
                    tokensByMonthWeekday: tokensByMonthWeekday,
                    maxTokens: maxYearWeekdayTokens,
                    displayYear: displayYear,
                    calendar: calendar,
                    onHoverSummaryChange: { hoverSummary = $0 },
                    onSelectMonth: onSelectMonth
                )
            }

            AgentUsageActivityLegendView(colorScheme: colorScheme)
        }
    }

    private var monthCells: [AgentUsageActivityCalendarCell] {
        AgentUsageActivityCalendarLayout.monthCells(for: displayMonth, calendar: calendar)
    }

    private var yearMonths: [AgentUsageActivityDisplayMonth] {
        AgentUsageActivityCalendarLayout.yearMonths(for: displayYear, calendar: calendar)
    }

    private var maxTokens: Int {
        max(dataPoints.map(\.totalTokens).max() ?? 0, 1)
    }

    private var tokenByDay: [Int: Int] {
        var values: [Int: Int] = [:]
        for point in dataPoints {
            values[agentUsageDayIdentifier(for: point.date, calendar: calendar), default: 0] += point.totalTokens
        }
        return values
    }

    private var tokensByMonthWeekday: [String: Int] {
        var values: [String: Int] = [:]
        for point in dataPoints where calendar.component(.year, from: point.date) == displayYear {
            let month = calendar.component(.month, from: point.date)
            let weekday = AgentUsageActivityCalendarLayout.weekdayIndex(for: point.date, calendar: calendar)
            values["\(month)-\(weekday)", default: 0] += point.totalTokens
        }
        return values
    }

    private var maxYearWeekdayTokens: Int {
        max(tokensByMonthWeekday.values.max() ?? 0, 1)
    }
}

private struct AgentUsageActivityHoverSummary: Equatable {
    let title: String
    let valueText: String
    let detailText: String
}

private struct AgentUsageActivityHoverSummaryView: View {
    let summary: AgentUsageActivityHoverSummary?

    var body: some View {
        HStack(spacing: 6) {
            if let summary {
                Text(summary.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.appSecondaryText)
                Text(summary.valueText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.appPrimaryText)
                Text(summary.detailText)
                    .font(.system(size: 10))
                    .foregroundColor(.appTertiaryText)
            } else {
                Text("Hover a cell for usage")
                    .font(.system(size: 10))
                    .foregroundColor(.appTertiaryText)
            }
        }
        .lineLimit(1)
        .frame(height: 14, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentUsageActivityLegendView: View {
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 5) {
            Spacer()

            Text("Less")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.appTertiaryText)

            ForEach(Array(AgentUsageActivityColorPalette.activeLevels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AgentUsageActivityColorPalette.fillColor(for: level, colorScheme: colorScheme))
                    .frame(width: 12, height: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color.appFieldBorder.opacity(0.25), lineWidth: 0.5)
                    )
            }

            Text("More")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.appTertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token usage intensity legend, less to more")
    }
}

private struct AgentUsageActivityMonthView: View {
    let cells: [AgentUsageActivityCalendarCell]
    let tokenByDay: [Int: Int]
    let maxTokens: Int
    let calendar: Calendar
    let onHoverSummaryChange: (AgentUsageActivityHoverSummary?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let cellSpacing: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.appTertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: cellSpacing) {
                ForEach(cells) { cell in
                    let tokens = tokenByDay[cell.day, default: 0]
                    Text(dayText(for: cell))
                        .font(.system(size: 10, weight: tokens > 0 ? .semibold : .regular))
                        .foregroundColor(textColor(for: cell, tokens: tokens))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(color(for: tokens, isInRange: cell.isInDisplayedMonth))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.appFieldBorder.opacity(cell.isInDisplayedMonth ? 0.35 : 0.12), lineWidth: 0.5)
                        )
                        .onHover { isHovering in
                            onHoverSummaryChange(isHovering ? hoverSummary(for: cell, tokens: tokens) : nil)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: cellSpacing), count: 7)
    }

    private var weekdaySymbols: [String] {
        AgentUsageActivityCalendarLayout.weekdayLabels(calendar: calendar)
    }

    private func dayText(for cell: AgentUsageActivityCalendarCell) -> String {
        "\(calendar.component(.day, from: cell.date))"
    }

    private func color(for tokens: Int, isInRange: Bool) -> Color {
        guard isInRange else { return Color.clear }

        let level = AgentUsageActivityColorPalette.level(for: tokens, maxTokens: maxTokens)
        return AgentUsageActivityColorPalette.fillColor(for: level, colorScheme: colorScheme)
    }

    private func textColor(for cell: AgentUsageActivityCalendarCell, tokens: Int) -> Color {
        guard cell.isInDisplayedMonth else { return .appTertiaryText.opacity(0.55) }

        let level = AgentUsageActivityColorPalette.level(for: tokens, maxTokens: maxTokens)
        return AgentUsageActivityColorPalette.textColor(for: level, colorScheme: colorScheme)
    }

    private func hoverSummary(for cell: AgentUsageActivityCalendarCell, tokens: Int) -> AgentUsageActivityHoverSummary {
        AgentUsageActivityHoverSummary(
            title: shortDate(cell.date),
            valueText: "\(compact(tokens)) tokens",
            detailText: cell.isInDisplayedMonth ? "daily usage" : "outside displayed month"
        )
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
}

private struct AgentUsageActivityYearView: View {
    let months: [AgentUsageActivityDisplayMonth]
    let tokensByMonthWeekday: [String: Int]
    let maxTokens: Int
    let displayYear: Int
    let calendar: Calendar
    let onHoverSummaryChange: (AgentUsageActivityHoverSummary?) -> Void
    let onSelectMonth: (AgentUsageActivityDisplayMonth) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let cellSpacing: CGFloat = 4
    private let cellHeight: CGFloat = 9

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: cellSpacing) {
                Color.clear
                    .frame(width: 26, height: 10)

                ForEach(weekdayLabels.indices, id: \.self) { index in
                    Text(weekdayLabels[index])
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.appTertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 26, height: cellHeight, alignment: .trailing)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(months, id: \.month) { month in
                    VStack(spacing: cellSpacing) {
                        Button {
                            onSelectMonth(month)
                        } label: {
                            Text(monthLabel(for: month))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.appTertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .frame(height: 10)
                        }
                        .buttonStyle(.plain)

                        ForEach(weekdayLabels.indices, id: \.self) { weekdayIndex in
                            let tokens = tokens(for: month, weekdayIndex: weekdayIndex)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color(for: tokens))
                                .frame(height: cellHeight)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .stroke(Color.appFieldBorder.opacity(0.25), lineWidth: 0.5)
                                )
                                .onHover { isHovering in
                                    onHoverSummaryChange(isHovering ? hoverSummary(for: month, weekdayIndex: weekdayIndex, tokens: tokens) : nil)
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: cellSpacing), count: 12)
    }

    private var weekdayLabels: [String] {
        AgentUsageActivityCalendarLayout.weekdayLabels(calendar: calendar)
    }

    private func tokens(for month: AgentUsageActivityDisplayMonth, weekdayIndex: Int) -> Int {
        tokensByMonthWeekday["\(month.month)-\(weekdayIndex)", default: 0]
    }

    private func color(for tokens: Int) -> Color {
        let level = AgentUsageActivityColorPalette.level(for: tokens, maxTokens: maxTokens)
        return AgentUsageActivityColorPalette.fillColor(for: level, colorScheme: colorScheme)
    }

    private func monthLabel(for month: AgentUsageActivityDisplayMonth) -> String {
        let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) ?? Date()
        return date.formatted(.dateTime.month(.abbreviated))
    }

    private func hoverSummary(for month: AgentUsageActivityDisplayMonth, weekdayIndex: Int, tokens: Int) -> AgentUsageActivityHoverSummary {
        AgentUsageActivityHoverSummary(
            title: "\(monthLabel(for: month)) \(displayYear)",
            valueText: "\(compact(tokens)) tokens",
            detailText: "\(weekdayLabels[weekdayIndex]) total"
        )
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
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
