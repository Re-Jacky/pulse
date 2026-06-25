import AppKit
import Combine

private enum AgentStatusMenuBarMetrics {
    static let horizontalPadding: CGFloat = 4
    static let agentIconAdvance: CGFloat = 17
    static let agentIconSize: CGFloat = 14
    static let slotAdvance: CGFloat = 10
    static let overflowMinimumAdvance: CGFloat = 13
    static let agentGroupGap: CGFloat = 6
}

final class MenuBarStatusItemView: NSControl {
    static let defaultWidth: CGFloat = 1

    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onLeftClickAgent: ((AgentStatusAgent) -> Void)?
    var onRightClickAgent: ((AgentStatusAgent) -> Void)?
    var onPreferredWidthChange: ((CGFloat) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var renderedGroups: [AgentStatusGroup] = []
    private var settingsEnabled = false
    private var selectedAgents = Set<AgentStatusAgent>()
    private var groupRegions: [AgentGroupRegion] = []
    private var pendingMouseActivation: PendingMouseActivation?
    private static let overflowAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .medium),
        .foregroundColor: NSColor.labelColor
    ]

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

    override func mouseDown(with event: NSEvent) {
        beginMouseActivation(
            kind: event.modifierFlags.contains(.control) ? .secondary : .primary
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        beginMouseActivation(kind: .secondary)
    }

    override func mouseUp(with event: NSEvent) {
        completeMouseActivation(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        completeMouseActivation(at: convert(event.locationInWindow, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let visibleGroups = visibleGroups
        var cursorX = AgentStatusMenuBarMetrics.horizontalPadding

        for (index, group) in visibleGroups.enumerated() {
            if index > 0 {
                cursorX += AgentStatusMenuBarMetrics.agentGroupGap
            }

            drawAgentIcon(
                group.agent,
                in: NSRect(
                    x: cursorX,
                    y: bounds.midY - AgentStatusMenuBarMetrics.agentIconSize / 2,
                    width: AgentStatusMenuBarMetrics.agentIconSize,
                    height: AgentStatusMenuBarMetrics.agentIconSize
                )
            )
            cursorX += AgentStatusMenuBarMetrics.agentIconAdvance

            for slot in visibleSlots(for: group) {
                drawLight(slot.state, at: NSPoint(x: cursorX + 4, y: bounds.midY))
                cursorX += AgentStatusMenuBarMetrics.slotAdvance
            }

            if group.overflowCount > 0 {
                drawOverflow(group.overflowCount, at: NSPoint(x: cursorX, y: bounds.midY))
                cursorX += overflowAdvance(for: group.overflowCount)
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
        if let agent = visibleGroups.first?.agent {
            onLeftClickAgent?(agent)
        } else {
            onLeftClick?()
        }
        return true
    }

    private func beginMouseActivation(kind: PendingMouseActivation) {
        pendingMouseActivation = kind
    }

    private func completeMouseActivation(at point: NSPoint) {
        guard let pendingMouseActivation else {
            return
        }

        self.pendingMouseActivation = nil
        guard bounds.contains(point) else {
            return
        }

        let resolvedAgent = resolvedAgent(at: point)

        switch pendingMouseActivation {
        case .primary:
            if let resolvedAgent {
                onLeftClickAgent?(resolvedAgent)
            } else {
                onLeftClick?()
            }
        case .secondary:
            if let resolvedAgent {
                onRightClickAgent?(resolvedAgent)
            } else {
                onRightClick?()
            }
        }
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
        recalculateGroupRegions()

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

    private func recalculateGroupRegions() {
        guard visibleGroups.isEmpty == false else {
            groupRegions = []
            return
        }

        var cursorX = AgentStatusMenuBarMetrics.horizontalPadding
        var regions: [AgentGroupRegion] = []

        for (index, group) in visibleGroups.enumerated() {
            if index > 0 {
                cursorX += AgentStatusMenuBarMetrics.agentGroupGap
            }

            let startX = cursorX
            cursorX += AgentStatusMenuBarMetrics.agentIconAdvance
            cursorX += CGFloat(visibleSlots(for: group).count) * AgentStatusMenuBarMetrics.slotAdvance

            if group.overflowCount > 0 {
                cursorX += overflowAdvance(for: group.overflowCount)
            }

            regions.append(
                AgentGroupRegion(
                    agent: group.agent,
                    frame: NSRect(x: startX, y: 0, width: cursorX - startX, height: bounds.height)
                )
            )
        }

        groupRegions = regions
    }

    private var preferredWidth: CGFloat {
        guard visibleGroups.isEmpty == false else {
            return Self.defaultWidth
        }

        var width = AgentStatusMenuBarMetrics.horizontalPadding * 2

        for (index, group) in visibleGroups.enumerated() {
            if index > 0 {
                width += AgentStatusMenuBarMetrics.agentGroupGap
            }

            width += AgentStatusMenuBarMetrics.agentIconAdvance
            width += CGFloat(visibleSlots(for: group).count) * AgentStatusMenuBarMetrics.slotAdvance
            if group.overflowCount > 0 {
                width += overflowAdvance(for: group.overflowCount)
            }
        }

        return max(Self.defaultWidth, width)
    }

    private func visibleSlots(for group: AgentStatusGroup) -> ArraySlice<AgentSessionSlot> {
        group.slots.prefix(4)
    }

    private func drawAgentIcon(_ agent: AgentStatusAgent, in rect: NSRect) {
        guard let icon = AgentBrandIcon(agent: agent) else {
            return
        }

        icon.draw(in: rect, color: .labelColor)
    }

    private func drawLight(_ state: AgentSessionLightState, at center: NSPoint) {
        let rect = NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        let path = NSBezierPath(ovalIn: rect)

        switch state {
        case .empty:
            AgentSessionLightColor.nsColor(for: state).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .working, .idle, .error:
            AgentSessionLightColor.nsColor(for: state).setFill()
            path.fill()
        }
    }

    private func drawOverflow(_ count: Int, at center: NSPoint) {
        let text = "+\(count)"
        let size = text.size(withAttributes: Self.overflowAttributes)
        text.draw(
            at: NSPoint(x: center.x, y: center.y - size.height / 2),
            withAttributes: Self.overflowAttributes
        )
    }

    private func overflowAdvance(for count: Int) -> CGFloat {
        let text = "+\(count)"
        let size = text.size(withAttributes: Self.overflowAttributes)
        return max(AgentStatusMenuBarMetrics.overflowMinimumAdvance, size.width + 2)
    }

    private func resolvedAgent(at point: NSPoint) -> AgentStatusAgent? {
        groupRegions.first(where: { $0.frame.contains(point) })?.agent
    }

}

#if DEBUG
extension MenuBarStatusItemView {
    func configureForTesting(
        groups: [AgentStatusGroup],
        isEnabled: Bool,
        selectedAgents: Set<AgentStatusAgent>
    ) {
        render(groups: groups, isEnabled: isEnabled, selectedAgents: selectedAgents)
    }

    func agent(at point: NSPoint) -> AgentStatusAgent? {
        resolvedAgent(at: point)
    }

    func groupFrame(for agent: AgentStatusAgent) -> NSRect? {
        groupRegions.first(where: { $0.agent == agent })?.frame
    }

    func performLeftMouseDownForTesting(at point: NSPoint) {
        guard bounds.contains(point) else {
            return
        }

        beginMouseActivation(kind: .primary)
    }

    func performLeftMouseUpForTesting(at point: NSPoint) {
        completeMouseActivation(at: point)
    }

    static func color(for state: AgentSessionLightState) -> NSColor {
        AgentSessionLightColor.nsColor(for: state)
    }
}
#endif

private enum PendingMouseActivation {
    case primary
    case secondary
}

private struct AgentGroupRegion {
    let agent: AgentStatusAgent
    let frame: NSRect
}

private struct AgentBrandIcon {
    let viewBox: CGSize
    let pathData: String

    init?(agent: AgentStatusAgent) {
        switch agent {
        case .openCode:
            viewBox = CGSize(width: 24, height: 30)
            pathData = "M18 6H6V24H18V6ZM24 30H0V0H24V30Z"
        case .codex:
            viewBox = CGSize(width: 22, height: 22)
            pathData = "M8.43799 8.06943V6.09387C8.43799 5.92749 8.50347 5.80267 8.65601 5.71959L12.8206 3.43211C13.3875 3.1202 14.0635 2.9747 14.7611 2.9747C17.3775 2.9747 19.0347 4.9087 19.0347 6.96734C19.0347 7.11288 19.0347 7.27926 19.0128 7.44564L14.6956 5.03335C14.434 4.88785 14.1723 4.88785 13.9107 5.03335L8.43799 8.06943ZM18.1624 15.7637V11.0431C18.1624 10.7519 18.0315 10.544 17.7699 10.3984L12.2972 7.36234L14.0851 6.3849C14.2377 6.30182 14.3686 6.30182 14.5212 6.3849L18.6858 8.67238C19.8851 9.3379 20.6917 10.7519 20.6917 12.1243C20.6917 13.7047 19.7106 15.1604 18.1624 15.7636V15.7637ZM7.15158 11.6047L5.36369 10.6066C5.21114 10.5235 5.14566 10.3986 5.14566 10.2323V5.65735C5.14566 3.43233 6.93355 1.7478 9.35381 1.7478C10.2697 1.7478 11.1199 2.039 11.8396 2.55886L7.54424 4.92959C7.28268 5.07508 7.15181 5.28303 7.15181 5.57427V11.6049L7.15158 11.6047ZM11 13.7258L8.43799 12.3533V9.44209L11 8.06965L13.5618 9.44209V12.3533L11 13.7258ZM12.6461 20.0476C11.7303 20.0476 10.8801 19.7564 10.1604 19.2366L14.4557 16.8658C14.7173 16.7203 14.8482 16.5124 14.8482 16.2211V10.1905L16.658 11.1886C16.8105 11.2717 16.876 11.3965 16.876 11.563V16.1379C16.876 18.3629 15.0662 20.0474 12.6461 20.0474V20.0476ZM7.47863 15.4103L3.314 13.1229C2.11471 12.4573 1.30808 11.0433 1.30808 9.67088C1.30808 8.06965 2.31106 6.6348 3.85903 6.03168V10.773C3.85903 11.0642 3.98995 11.2721 4.25151 11.4177L9.70253 14.4328L7.91464 15.4103C7.76209 15.4934 7.63117 15.4934 7.47863 15.4103ZM7.23892 18.8207C4.77508 18.8207 2.96533 17.0531 2.96533 14.8696C2.96533 14.7032 2.98719 14.5368 3.00886 14.3704L7.30418 16.7412C7.56574 16.8867 7.82752 16.8867 8.08909 16.7412L13.5618 13.726V15.7015C13.5618 15.8679 13.4964 15.9927 13.3438 16.0758L9.17918 18.3633C8.61225 18.6752 7.93631 18.8207 7.23869 18.8207H7.23892ZM12.6461 21.2952C15.2844 21.2952 17.4865 19.5069 17.9882 17.1362C20.4301 16.5331 22 14.3495 22 12.1245C22 10.6688 21.346 9.25482 20.1685 8.23581C20.2775 7.79908 20.343 7.36234 20.343 6.92582C20.343 3.95215 17.8137 1.72691 14.892 1.72691C14.3034 1.72691 13.7365 1.80999 13.1695 1.99726C12.1882 1.08223 10.8364 0.5 9.35381 0.5C6.71557 0.5 4.51352 2.28829 4.01185 4.65902C1.56987 5.26214 0 7.44564 0 9.67067C0 11.1264 0.654039 12.5404 1.83147 13.5594C1.72246 13.9961 1.65702 14.4328 1.65702 14.8694C1.65702 17.8431 4.1863 20.0683 7.108 20.0683C7.69661 20.0683 8.26354 19.9852 8.83046 19.7979C9.81155 20.713 11.1634 21.2952 12.6461 21.2952Z"
        }
    }

    func draw(in rect: NSRect, color: NSColor) {
        guard let path = SVGPathParser.makePath(from: pathData) else {
            return
        }

        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let fittedSize = CGSize(width: viewBox.width * scale, height: viewBox.height * scale)
        let fittedRect = NSRect(
            x: rect.midX - fittedSize.width / 2,
            y: rect.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )

        let transform = NSAffineTransform()
        transform.translateX(by: fittedRect.minX, yBy: fittedRect.maxY)
        transform.scaleX(by: scale, yBy: -scale)
        NSGraphicsContext.current?.saveGraphicsState()
        transform.concat()
        color.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

private enum SVGPathParser {
    static func makePath(from pathData: String) -> NSBezierPath? {
        let tokens = tokenize(pathData)
        guard tokens.isEmpty == false else {
            return nil
        }

        let path = NSBezierPath()
        var index = 0
        var command: String?
        var currentPoint = CGPoint.zero

        while index < tokens.count {
            if isCommand(tokens[index]) {
                command = tokens[index]
                index += 1
            }

            guard let activeCommand = command else {
                return nil
            }

            switch activeCommand {
            case "M":
                guard let point = readPoint(tokens, &index) else { return nil }
                path.move(to: point)
                currentPoint = point
                while hasNumber(tokens, at: index), let nextPoint = readPoint(tokens, &index) {
                    path.line(to: nextPoint)
                    currentPoint = nextPoint
                }
            case "L":
                while hasNumber(tokens, at: index), let point = readPoint(tokens, &index) {
                    path.line(to: point)
                    currentPoint = point
                }
            case "H":
                while hasNumber(tokens, at: index), let x = readNumber(tokens, &index) {
                    currentPoint = CGPoint(x: x, y: currentPoint.y)
                    path.line(to: currentPoint)
                }
            case "V":
                while hasNumber(tokens, at: index), let y = readNumber(tokens, &index) {
                    currentPoint = CGPoint(x: currentPoint.x, y: y)
                    path.line(to: currentPoint)
                }
            case "C":
                while hasNumber(tokens, at: index),
                      let control1 = readPoint(tokens, &index),
                      let control2 = readPoint(tokens, &index),
                      let point = readPoint(tokens, &index) {
                    path.curve(to: point, controlPoint1: control1, controlPoint2: control2)
                    currentPoint = point
                }
            case "Z":
                path.close()
                command = nil
            default:
                return nil
            }
        }

        return path
    }

    private static func tokenize(_ pathData: String) -> [String] {
        let scalars = Array(pathData.unicodeScalars)
        var tokens: [String] = []
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "," {
                index += 1
            } else if isCommandScalar(scalar) {
                tokens.append(String(scalar))
                index += 1
            } else {
                let start = index
                index += 1
                while index < scalars.count {
                    let previous = scalars[index - 1]
                    let current = scalars[index]
                    if CharacterSet.whitespacesAndNewlines.contains(current) || current == "," || isCommandScalar(current) {
                        break
                    }
                    if (current == "-" || current == "+") && previous != "e" && previous != "E" {
                        break
                    }
                    index += 1
                }
                tokens.append(String(String.UnicodeScalarView(scalars[start..<index])))
            }
        }

        return tokens
    }

    private static func isCommand(_ token: String) -> Bool {
        token.count == 1 && "MLHVCZ".contains(token)
    }

    private static func isCommandScalar(_ scalar: UnicodeScalar) -> Bool {
        "MLHVCZ".unicodeScalars.contains(scalar)
    }

    private static func hasNumber(_ tokens: [String], at index: Int) -> Bool {
        index < tokens.count && isCommand(tokens[index]) == false
    }

    private static func readPoint(_ tokens: [String], _ index: inout Int) -> CGPoint? {
        guard let x = readNumber(tokens, &index),
              let y = readNumber(tokens, &index) else {
            return nil
        }

        return CGPoint(x: x, y: y)
    }

    private static func readNumber(_ tokens: [String], _ index: inout Int) -> CGFloat? {
        guard index < tokens.count,
              let value = Double(tokens[index]) else {
            return nil
        }

        index += 1
        return CGFloat(value)
    }
}
