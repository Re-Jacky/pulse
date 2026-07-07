import SwiftUI

struct AgentStatusManagementView: View {
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    @EnvironmentObject var agentIntegrationManager: AgentIntegrationManager
    @Environment(AgentStatusPanelSelection.self) private var panelSelection

    private var selectedAgent: AgentStatusAgent {
        panelSelection.selectedAgent
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header

                ForEach(Self.visibleGroups(agentStatusStore.groups, selection: panelSelection)) { group in
                    groupSection(group)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedAgent.displayName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Review this agent's live sessions and integration status.")
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func visibleGroups(
        _ groups: [AgentStatusGroup],
        selectedAgent: AgentStatusAgent
    ) -> [AgentStatusGroup] {
        groups.filter { $0.agent == selectedAgent }
    }

    static func visibleGroups(
        _ groups: [AgentStatusGroup],
        selection: AgentStatusPanelSelection
    ) -> [AgentStatusGroup] {
        visibleGroups(groups, selectedAgent: selection.selectedAgent)
    }

    private func groupSection(_ group: AgentStatusGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            integrationCard(for: agentIntegrationManager.status(for: group.agent))
            sessionsSection(group)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func integrationCard(for status: AgentIntegrationStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.agent.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.appPrimaryText)

                    Text("Integration")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.appSecondaryText)
                }

                Spacer()

                Text(status.displayStateTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.appPrimaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSidebarBackground.opacity(0.8))
                    .clipShape(Capsule())
            }

            if status.guidance.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status.guidance, id: \.self) { step in
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundColor(.appSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(status.primaryActionTitle) {
                    try? agentIntegrationManager.performPrimaryAction(for: status.agent)
                }
                .buttonStyle(.borderedProminent)

                ForEach(status.secondaryActions, id: \.self) { title in
                    Button(title) {
                        try? agentIntegrationManager.performSecondaryAction(title, for: status.agent)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(Color.appSidebarBackground.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sessionsSection(_ group: AgentStatusGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Spacer()

                Button("Clear Idle") {
                    agentStatusStore.clearIdleSlots(for: group.agent)
                }
                .disabled(group.slots.contains { $0.state == .idle } == false)

                Button("Clear All") {
                    agentStatusStore.clearAllSlots(for: group.agent)
                }
                .disabled(group.slots.allSatisfy(\.isPlaceholder))
            }

            VStack(spacing: 8) {
                ForEach(group.slots) { slot in
                    slotRow(slot)
                }
            }
        }
    }

    private func slotRow(_ slot: AgentSessionSlot) -> some View {
        HStack(spacing: 10) {
            light(for: slot.state)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.projectName ?? "Empty Slot")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.appPrimaryText)
                    .lineLimit(1)

                ForEach(Self.detailLines(for: slot)) { detail in
                    if let tooltip = detail.tooltip {
                        TooltipTextLine(text: detail.text, tooltip: tooltip)
                    } else {
                        Text(detail.text)
                            .font(.system(size: 12))
                            .foregroundColor(.appSecondaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(slot.state.rawValue.capitalized)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color(for: slot.state))

            Button("Delete") {
                agentStatusStore.deleteSlot(agent: slot.agent, slotID: slot.id)
            }
            .disabled(slot.isPlaceholder)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appSidebarBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func detailLines(for slot: AgentSessionSlot) -> [SlotDetailLine] {
        var details: [SlotDetailLine] = []

        if let sessionTitle = slot.sessionTitle, sessionTitle.isEmpty == false {
            details.append(SlotDetailLine(text: sessionTitle, tooltip: nil))
        }

        if let sessionID = slot.sessionID, sessionID.isEmpty == false {
            details.append(SlotDetailLine(text: "Session ID: \(sessionID)", tooltip: sessionID))
        }

        if let projectPath = slot.projectPath, projectPath.isEmpty == false {
            details.append(SlotDetailLine(text: projectPath, tooltip: projectPath))
        }

        return details.isEmpty ? [SlotDetailLine(text: "Waiting for a session", tooltip: nil)] : details
    }

    private func light(for state: AgentSessionLightState) -> some View {
        Circle()
            .strokeBorder(color(for: state), lineWidth: state == .empty ? 1 : 0)
            .background(
                Circle()
                    .fill(state == .empty ? Color.clear : color(for: state))
            )
    }

    private func color(for state: AgentSessionLightState) -> Color {
        AgentSessionLightColor.swiftUIColor(for: state)
    }
}

#if DEBUG
extension AgentStatusManagementView {
    static func color(for state: AgentSessionLightState) -> Color {
        AgentSessionLightColor.swiftUIColor(for: state)
    }

    static func detailLineTexts(for slot: AgentSessionSlot) -> [String] {
        detailLines(for: slot).map(\.text)
    }
}
#endif

private struct SlotDetailLine: Identifiable {
    let id = UUID()
    let text: String
    let tooltip: String?
}

enum TooltipPresentation {
    static func shouldShowTooltip(isHovering: Bool, tooltip: String) -> Bool {
        isHovering && tooltip.isEmpty == false
    }
}

struct TooltipTextLine: View {
    let text: String
    let tooltip: String

    @State private var isHovering = false

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .overlay(alignment: .topLeading) {
                if TooltipPresentation.shouldShowTooltip(isHovering: isHovering, tooltip: tooltip) {
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.9))
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -30)
                        .zIndex(1)
                }
            }
            .zIndex(isHovering ? 1 : 0)
    }
}
