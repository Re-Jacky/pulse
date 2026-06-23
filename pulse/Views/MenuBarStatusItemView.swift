import AppKit
import Combine

final class MenuBarStatusItemView: NSControl {
    static let defaultWidth: CGFloat = 1

    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onPreferredWidthChange: ((CGFloat) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var renderedGroups: [AgentStatusGroup] = []
    private var settingsEnabled = false
    private var selectedAgents = Set<AgentStatusAgent>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func bind(to store: AgentStatusStore, settings: AgentLightsSettings) {
        cancellables.removeAll()

        store.$groups
            .combineLatest(settings.$isEnabled, settings.$selectedAgents)
            .receive(on: RunLoop.main)
            .sink { [weak self] groups, isEnabled, selectedAgents in
                self?.render(groups: groups, isEnabled: isEnabled, selectedAgents: selectedAgents)
            }
            .store(in: &cancellables)

        render(
            groups: store.groups,
            isEnabled: settings.isEnabled,
            selectedAgents: settings.selectedAgents
        )
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let visibleGroups = visibleGroups
        var cursorX: CGFloat = 4

        for group in visibleGroups {
            drawAgentBadge(group.agent, at: NSPoint(x: cursorX, y: bounds.midY))
            cursorX += 17

            for slot in visibleSlots(for: group) {
                drawLight(slot.state, at: NSPoint(x: cursorX + 4, y: bounds.midY))
                cursorX += 10
            }

            if group.overflowCount > 0 {
                drawOverflow(group.overflowCount, at: NSPoint(x: cursorX, y: bounds.midY))
                cursorX += 13
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        toolTip = accessibilityLabel()
    }

    override func accessibilityLabel() -> String? {
        guard settingsEnabled else {
            return "Agent Lights"
        }

        let descriptions = visibleGroups.map { group in
            let states = group.slots.map(\.state.rawValue).joined(separator: ", ")
            return "\(group.agent.displayName): \(states)"
        }

        return descriptions.isEmpty ? "Agent Lights" : "Agent Lights, " + descriptions.joined(separator: "; ")
    }

    override func accessibilityHelp() -> String? {
        "Open Agent Lights"
    }

    override func accessibilityPerformPress() -> Bool {
        onLeftClick?()
        return true
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func render(
        groups: [AgentStatusGroup],
        isEnabled: Bool,
        selectedAgents: Set<AgentStatusAgent>
    ) {
        renderedGroups = groups
        settingsEnabled = isEnabled
        self.selectedAgents = selectedAgents

        let width = preferredWidth
        if abs(frame.width - width) > 0.5 {
            frame.size.width = width
            onPreferredWidthChange?(width)
        }

        toolTip = accessibilityLabel()
        needsDisplay = true
    }

    private var visibleGroups: [AgentStatusGroup] {
        guard settingsEnabled else {
            return []
        }

        return renderedGroups.filter { selectedAgents.contains($0.agent) }
    }

    private var preferredWidth: CGFloat {
        guard visibleGroups.isEmpty == false else {
            return Self.defaultWidth
        }

        var width: CGFloat = 8

        for group in visibleGroups {
            width += 17
            width += CGFloat(visibleSlots(for: group).count) * 10
            if group.overflowCount > 0 {
                width += 13
            }
        }

        return max(Self.defaultWidth, width)
    }

    private func visibleSlots(for group: AgentStatusGroup) -> ArraySlice<AgentSessionSlot> {
        group.slots.prefix(4)
    }

    private func drawAgentBadge(_ agent: AgentStatusAgent, at center: NSPoint) {
        let rect = NSRect(x: center.x, y: center.y - 6, width: 15, height: 12)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        path.fill()

        let glyph = initials(for: agent)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawLight(_ state: AgentSessionLightState, at center: NSPoint) {
        let rect = NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        let path = NSBezierPath(ovalIn: rect)

        switch state {
        case .empty:
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .working:
            NSColor.systemOrange.setFill()
            path.fill()
        case .idle:
            NSColor.systemGreen.setFill()
            path.fill()
        case .error:
            NSColor.systemRed.setFill()
            path.fill()
        }
    }

    private func drawOverflow(_ count: Int, at center: NSPoint) {
        let text = "+\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: center.x, y: center.y - size.height / 2),
            withAttributes: attributes
        )
    }

    private func initials(for agent: AgentStatusAgent) -> String {
        switch agent {
        case .openCode:
            return "OC"
        case .codex:
            return "CX"
        }
    }
}
