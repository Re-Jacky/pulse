import SwiftUI

struct AgentDateSelectionPicker: View {
    let selection: AgentDateSelection
    let onApply: (AgentDateSelection) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))

                Text(AgentDateSelectionTriggerLabel.text(for: selection))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.appSecondaryText)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.appPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appFieldBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.appFieldBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentDateSelectionPopover(
                initialSelection: selection,
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
        let startOfReferenceDay = Date(timeIntervalSince1970: TimeInterval(day) * secondsPerDay)
        return calendar.startOfDay(for: startOfReferenceDay)
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

private struct AgentDateSelectionPopover: View {
    let onCancel: () -> Void
    let onApply: (AgentDateSelection) -> Void

    @Environment(\.calendar) private var calendar
    @State private var mode: Mode
    @State private var selectedPreset: AgentDatePreset
    @State private var startDate: Date
    @State private var endDate: Date

    init(
        initialSelection: AgentDateSelection,
        onCancel: @escaping () -> Void,
        onApply: @escaping (AgentDateSelection) -> Void
    ) {
        let calendar = Calendar.autoupdatingCurrent
        let resolvedPreset = initialSelection.preset ?? .today
        let defaultDate = calendar.startOfDay(for: Date())

        _mode = State(initialValue: initialSelection.preset == nil ? .custom : .preset)
        _selectedPreset = State(initialValue: resolvedPreset)

        switch initialSelection {
        case .preset:
            _startDate = State(initialValue: defaultDate)
            _endDate = State(initialValue: defaultDate)
        case let .singleDay(day):
            let selectedDate = AgentDateSelectionTriggerLabel.date(for: day, calendar: calendar)
            _startDate = State(initialValue: selectedDate)
            _endDate = State(initialValue: selectedDate)
        case let .dayRange(startDay, endDay):
            _startDate = State(initialValue: AgentDateSelectionTriggerLabel.date(for: min(startDay, endDay), calendar: calendar))
            _endDate = State(initialValue: AgentDateSelectionTriggerLabel.date(for: max(startDay, endDay), calendar: calendar))
        }

        self.onCancel = onCancel
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $mode) {
                Text("Preset").tag(Mode.preset)
                Text("Custom").tag(Mode.custom)
            }
            .pickerStyle(.segmented)

            if mode == .preset {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Range")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.appSecondaryText)

                    ForEach(AgentDatePreset.allCases) { preset in
                        Button {
                            selectedPreset = preset
                        } label: {
                            HStack {
                                Text(preset.label)
                                    .foregroundColor(.appPrimaryText)

                                Spacer()

                                if selectedPreset == preset {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedPreset == preset ? Color.accentColor.opacity(0.14) : Color.appFieldBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selectedPreset == preset ? Color.accentColor.opacity(0.45) : Color.appFieldBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom Range")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.appSecondaryText)

                    dateField(title: "Start", selection: $startDate)
                    dateField(title: "End", selection: $endDate)

                    Text(customSummaryText)
                        .font(.system(size: 11))
                        .foregroundColor(.appSecondaryText)
                }
            }

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
        .padding(14)
        .frame(width: 280)
    }

    private var resolvedSelection: AgentDateSelection {
        switch mode {
        case .preset:
            return .preset(selectedPreset)
        case .custom:
            let startDay = agentUsageDayIdentifier(for: startDate, calendar: calendar)
            let endDay = agentUsageDayIdentifier(for: endDate, calendar: calendar)
            if startDay == endDay {
                return .singleDay(startDay)
            }
            return .dayRange(startDay: startDay, endDay: endDay)
        }
    }

    private var customSummaryText: String {
        AgentDateSelectionTriggerLabel.text(for: resolvedSelection, calendar: calendar)
    }

    @ViewBuilder
    private func dateField(title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            DatePicker(
                "",
                selection: selection,
                displayedComponents: [.date]
            )
            .labelsHidden()
            .datePickerStyle(.field)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.appFieldBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.appFieldBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private enum Mode {
        case preset
        case custom
    }
}
