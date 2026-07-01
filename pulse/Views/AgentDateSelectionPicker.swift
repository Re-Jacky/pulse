import SwiftUI

struct AgentDateSelectionPicker: View {
    let selection: AgentDateSelection
    let customDraftSelection: AgentDateSelection?
    let onApply: (AgentDateSelection) -> Void

    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 0) {
            shortcutButton(title: "Today", selectionValue: .preset(.today))
            shortcutButton(title: "All Time", selectionValue: .preset(.allTime))

            customButton
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.appFieldBorder, lineWidth: 1)
        )
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentDateSelectionPopover(
                initialSelection: customSelectionSeed,
                onCancel: {
                    isPresented = false
                },
                onApply: { updatedSelection in
                    onApply(updatedSelection)
                    isPresented = false
                }
            )
        }
    }

    private var customTagIsSelected: Bool {
        switch selection {
        case .preset(.today), .preset(.allTime):
            return false
        case .preset, .singleDay, .dayRange:
            return true
        }
    }

    private var customTagText: String {
        agentDateSelectionCustomTagText(
            activeSelection: selection,
            customDraftSelection: customDraftSelection
        )
    }

    private var customSelectionSeed: AgentDateSelection {
        switch selection {
        case .preset(.today), .preset(.allTime):
            return customDraftSelection ?? .singleDay(agentUsageDayIdentifier(for: Date()))
        case .preset, .singleDay, .dayRange:
            return selection
        }
    }

    private var customPrimaryAction: AgentDateSelectionCustomTagAction {
        agentDateSelectionCustomTagPrimaryAction(
            activeSelection: selection,
            customDraftSelection: customDraftSelection
        )
    }

    private func shortcutButton(title: String, selectionValue: AgentDateSelection) -> some View {
        let isSelected = selection == selectionValue

        return Button {
            onApply(selectionValue)
        } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .appPrimaryText : .appSecondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customButton: some View {
        HStack(spacing: 0) {
            Button(action: handleCustomPrimaryAction) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))

                    Text(customTagText)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                isPresented = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.leading, 2)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: customTagIsSelected ? .semibold : .medium))
        .foregroundColor(customTagIsSelected ? .appPrimaryText : .appSecondaryText)
        .background(customTagIsSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func handleCustomPrimaryAction() {
        switch customPrimaryAction {
        case .openPopover:
            isPresented = true
        case let .applySelection(selection):
            onApply(selection)
        }
    }
}

enum AgentDateSelectionCustomTagAction: Equatable {
    case openPopover
    case applySelection(AgentDateSelection)
}

struct AgentDateSelectionTriggerLabel {
    static func text(
        for selection: AgentDateSelection,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        switch selection {
        case let .preset(preset):
            return preset.label
        case let .singleDay(day):
            return singleDayFormatter(calendar: calendar).string(from: date(for: day, calendar: calendar))
        case let .dayRange(startDay, endDay):
            let lowerDay = min(startDay, endDay)
            let upperDay = max(startDay, endDay)
            let startDate = date(for: lowerDay, calendar: calendar)
            let endDate = date(for: upperDay, calendar: calendar)

            if calendar.component(.year, from: startDate) == calendar.component(.year, from: endDate) {
                return "\(rangeStartFormatter(calendar: calendar).string(from: startDate)) - \(rangeEndFormatter(calendar: calendar).string(from: endDate))"
            }

            return "\(singleDayFormatter(calendar: calendar).string(from: startDate)) - \(singleDayFormatter(calendar: calendar).string(from: endDate))"
        }
    }

    static func date(for day: Int, calendar: Calendar) -> Date {
        let secondsPerDay: TimeInterval = 86_400
        let referenceDate = Date(timeIntervalSince1970: TimeInterval(day) * secondsPerDay)
        let utcAlignedDate = referenceDate.addingTimeInterval(TimeInterval(calendar.timeZone.secondsFromGMT(for: referenceDate)))
        let candidate = calendar.startOfDay(for: utcAlignedDate)

        if agentUsageDayIdentifier(for: candidate, calendar: calendar) == day {
            return candidate
        }

        for offset in [-1, 1] {
            guard let adjustedDate = calendar.date(byAdding: .day, value: offset, to: candidate) else {
                continue
            }

            if agentUsageDayIdentifier(for: adjustedDate, calendar: calendar) == day {
                return adjustedDate
            }
        }

        return candidate
    }

    private static func singleDayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }

    private static func rangeStartFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private static func rangeEndFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter
    }
}

struct AgentDateSelectionInlineTagLabel {
    static func customText(
        for selection: AgentDateSelection,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        switch selection {
        case .preset(.today), .preset(.allTime):
            return "Custom"
        case .preset, .singleDay, .dayRange:
            return AgentDateSelectionTriggerLabel.text(for: selection, calendar: calendar)
        }
    }
}

func agentDateSelectionCustomTagText(
    activeSelection: AgentDateSelection,
    customDraftSelection: AgentDateSelection?,
    calendar: Calendar = .autoupdatingCurrent
) -> String {
    switch activeSelection {
    case .preset(.today), .preset(.allTime):
        guard let customDraftSelection else {
            return "Custom"
        }
        return AgentDateSelectionTriggerLabel.text(for: customDraftSelection, calendar: calendar)
    case .preset, .singleDay, .dayRange:
        return AgentDateSelectionTriggerLabel.text(for: activeSelection, calendar: calendar)
    }
}

func agentDateSelectionCustomTagPrimaryAction(
    activeSelection: AgentDateSelection,
    customDraftSelection: AgentDateSelection?
) -> AgentDateSelectionCustomTagAction {
    switch activeSelection {
    case .preset(.today), .preset(.allTime):
        guard let customDraftSelection else {
            return .openPopover
        }
        return .applySelection(customDraftSelection)
    case .preset, .singleDay, .dayRange:
        return .applySelection(activeSelection)
    }
}

private struct AgentDateSelectionPopover: View {
    let onCancel: () -> Void
    let onApply: (AgentDateSelection) -> Void

    @Environment(\.calendar) private var calendar
    @State private var startDate: Date
    @State private var endDate: Date

    init(
        initialSelection: AgentDateSelection,
        onCancel: @escaping () -> Void,
        onApply: @escaping (AgentDateSelection) -> Void
    ) {
        let calendar = Calendar.autoupdatingCurrent
        let dates = agentDateSelectionCalendarDates(
            for: initialSelection,
            calendar: calendar,
            now: Date()
        )
        _startDate = State(initialValue: dates.startDate)
        _endDate = State(initialValue: dates.endDate)

        self.onCancel = onCancel
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter a date only. Edit the year, month, or day directly.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)

            shortcutTags

            dateInputs

            summaryRow

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)

                Spacer()

                Button("Apply") {
                    onApply(resolvedSelection)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 356)
    }

    private var shortcutTags: some View {
        HStack(spacing: 8) {
            popupShortcutTag(title: "Yesterday", selection: .preset(.today), nowOffsetDays: -1)
            popupShortcutTag(title: "Last 7 Days", selection: .preset(.last7Days))
            popupShortcutTag(title: "Last 30 Days", selection: .preset(.last30Days))
        }
    }

    private var resolvedSelection: AgentDateSelection {
        let startDay = agentUsageDayIdentifier(for: startDate, calendar: calendar)
        let endDay = agentUsageDayIdentifier(for: endDate, calendar: calendar)
        if startDay == endDay {
            return .singleDay(startDay)
        }
        return .dayRange(startDay: startDay, endDay: endDay)
    }

    private var dateInputs: some View {
        VStack(spacing: 12) {
            dateInputRow(title: "Start", field: .start)
            dateInputRow(title: "End", field: .end)
        }
    }

    private func dateInputRow(title: String, field: AgentDateInputField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            NativeDateTextInput(
                date: binding(for: field),
                calendar: calendar
            )
            .frame(height: 38)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color.appFieldBackground,
                        Color(nsColor: .windowBackgroundColor).opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.appFieldBorder.opacity(0.8), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(summaryTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Spacer(minLength: 0)

            Text(selectionSummaryText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.appSecondaryText)
        }
    }

    private var summaryTitle: String {
        startDate == endDate ? "Selected day" : "Selected range"
    }

    private var selectionSummaryText: String {
        AgentDateSelectionTriggerLabel.text(for: resolvedSelection, calendar: calendar)
    }

    private func popupShortcutTag(
        title: String,
        selection: AgentDateSelection,
        nowOffsetDays: Int = 0
    ) -> some View {
        Button {
            let referenceNow = calendar.date(byAdding: .day, value: nowOffsetDays, to: Date()) ?? Date()
            let dates = agentDateSelectionCalendarDates(
                for: selection,
                calendar: calendar,
                now: referenceNow
            )
            startDate = dates.startDate
            endDate = dates.endDate
        } label: {
            Text(title)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.appPrimaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appFieldBackground)
                .overlay(
                    Capsule()
                        .stroke(Color.appFieldBorder, lineWidth: 1)
                )
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func binding(for field: AgentDateInputField) -> Binding<Date> {
        Binding(
            get: {
                switch field {
                case .start:
                    return startDate
                case .end:
                    return endDate
                }
            },
            set: { newDate in
                let updatedDates = agentDateSelectionDates(
                    byAssigning: calendar.startOfDay(for: newDate),
                    to: field,
                    startDate: startDate,
                    endDate: endDate
                )
                startDate = updatedDates.startDate
                endDate = updatedDates.endDate
            }
        )
    }

}

enum AgentDateInputField: String, Identifiable {
    case start
    case end

    var id: String { rawValue }
}

private struct NativeDateTextInput: NSViewRepresentable {
    @Binding var date: Date
    let calendar: Calendar

    func makeCoordinator() -> Coordinator {
        Coordinator(date: $date, calendar: calendar)
    }

    func makeNSView(context: Context) -> NativeDateTextInputView {
        let view = NativeDateTextInputView()
        view.configure(with: context.coordinator)
        context.coordinator.apply(date: calendar.startOfDay(for: date), to: view, force: true)
        return view
    }

    func updateNSView(_ nsView: NativeDateTextInputView, context: Context) {
        context.coordinator.calendar = calendar
        context.coordinator.apply(date: calendar.startOfDay(for: date), to: nsView)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var date: Date
        var calendar: Calendar
        private var lastAppliedDate: Date?
        private weak var view: NativeDateTextInputView?

        init(date: Binding<Date>, calendar: Calendar) {
            _date = date
            self.calendar = calendar
        }

        func apply(date: Date, to view: NativeDateTextInputView, force: Bool = false) {
            self.view = view

            guard force || view.isAnyFieldEditing == false else {
                return
            }

            if force || lastAppliedDate != date {
                view.setDateComponents(components(for: date))
                lastAppliedDate = date
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }

            sanitize(field: field)
            commitIfPossible()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            commitIfPossible(forceClamp: true)
            if let view {
                apply(date: calendar.startOfDay(for: date), to: view, force: true)
            }
        }

        private func sanitize(field: NSTextField) {
            let digitsOnly = field.stringValue.filter(\.isNumber)
            let maxLength = field == view?.yearField ? 4 : 2
            field.stringValue = String(digitsOnly.prefix(maxLength))
        }

        private func commitIfPossible(forceClamp: Bool = false) {
            guard let view else {
                return
            }

            let monthText = view.monthField.stringValue
            let dayText = view.dayField.stringValue
            let yearText = view.yearField.stringValue

            guard yearText.count == 4 else {
                return
            }

            guard forceClamp || (monthText.count == 2 && dayText.count == 2) else {
                return
            }

            guard let year = Int(yearText),
                  let month = Int(monthText),
                  let day = Int(dayText) else {
                return
            }

            let clampedMonth = min(max(month, 1), 12)
            let monthRange = calendar.range(of: .day, in: .month, for: dateFrom(year: year, month: clampedMonth, day: 1)) ?? (1..<32)
            let clampedDay = min(max(day, monthRange.lowerBound), monthRange.upperBound - 1)
            let committedDate = dateFrom(year: year, month: clampedMonth, day: clampedDay)
            lastAppliedDate = committedDate
            date = committedDate
        }

        private func components(for date: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day], from: date)
        }

        private func dateFrom(year: Int, month: Int, day: Int) -> Date {
            let rawDate = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
            return calendar.startOfDay(for: rawDate)
        }
    }
}

private final class NativeDateTextInputView: NSView {
    let monthField = NativeDatePartTextField(maxDigits: 2, placeholder: "MM")
    let dayField = NativeDatePartTextField(maxDigits: 2, placeholder: "DD")
    let yearField = NativeDatePartTextField(maxDigits: 4, placeholder: "YYYY")

    private let separatorOne = NativeDateSeparatorLabel(value: "/")
    private let separatorTwo = NativeDateSeparatorLabel(value: "/")

    var isAnyFieldEditing: Bool {
        window?.firstResponder is NSTextView
    }

    func configure(with coordinator: NativeDateTextInput.Coordinator) {
        [monthField, dayField, yearField].forEach { field in
            field.delegate = coordinator
            field.target = coordinator
        }
    }

    func setDateComponents(_ components: DateComponents) {
        monthField.stringValue = components.month.map { String(format: "%02d", $0) } ?? ""
        dayField.stringValue = components.day.map { String(format: "%02d", $0) } ?? ""
        yearField.stringValue = components.year.map { String(format: "%04d", $0) } ?? ""
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [monthField, separatorOne, dayField, separatorTwo, yearField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            monthField.widthAnchor.constraint(equalToConstant: 30),
            dayField.widthAnchor.constraint(equalToConstant: 30),
            yearField.widthAnchor.constraint(equalToConstant: 54)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class NativeDatePartTextField: NSTextField {
    private let maxDigits: Int

    init(maxDigits: Int, placeholder: String) {
        self.maxDigits = maxDigits
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        isBezeled = false
        isEditable = true
        isSelectable = true
        focusRingType = .none
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        textColor = .labelColor
        placeholderString = placeholder
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
    }

    override func textDidChange(_ notification: Notification) {
        if stringValue.count > maxDigits {
            stringValue = String(stringValue.prefix(maxDigits))
        }
        super.textDidChange(notification)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class NativeDateSeparatorLabel: NSTextField {
    init(value: String) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        textColor = .secondaryLabelColor
        stringValue = value
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

func agentDateSelectionCalendarDates(
    for selection: AgentDateSelection,
    calendar: Calendar = .autoupdatingCurrent,
    now: Date = Date()
) -> (startDate: Date, endDate: Date) {
    switch selection {
    case .preset(.today):
        let date = calendar.startOfDay(for: now)
        return (date, date)
    case .preset(.allTime):
        let date = calendar.startOfDay(for: now)
        return (date, date)
    case .preset(.last7Days), .preset(.last30Days):
        let interval = agentUsageDayInterval(for: selection, now: now, calendar: calendar)
        let lowerDay = interval?.lowerBound ?? agentUsageDayIdentifier(for: now, calendar: calendar)
        let upperDay = (interval?.upperBound ?? (lowerDay + 1)) - 1
        return (
            AgentDateSelectionTriggerLabel.date(for: lowerDay, calendar: calendar),
            AgentDateSelectionTriggerLabel.date(for: upperDay, calendar: calendar)
        )
    case let .singleDay(day):
        let date = AgentDateSelectionTriggerLabel.date(for: day, calendar: calendar)
        return (date, date)
    case let .dayRange(startDay, endDay):
        let lowerDay = min(startDay, endDay)
        let upperDay = max(startDay, endDay)
        return (
            AgentDateSelectionTriggerLabel.date(for: lowerDay, calendar: calendar),
            AgentDateSelectionTriggerLabel.date(for: upperDay, calendar: calendar)
        )
    }
}

func agentDateSelectionDates(
    byAssigning date: Date,
    to field: AgentDateInputField,
    startDate: Date,
    endDate: Date
) -> (startDate: Date, endDate: Date) {
    switch field {
    case .start:
        return (date, endDate)
    case .end:
        return (startDate, date)
    }
}
