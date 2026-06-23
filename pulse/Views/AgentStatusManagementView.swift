import SwiftUI

struct AgentStatusManagementView: View {
    @EnvironmentObject var agentStatusStore: AgentStatusStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ForEach(agentStatusStore.groups) { group in
                    groupSection(group)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent Status")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Map menu bar lights back to their projects, and remove idle or stale slots when you are done with them.")
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupSection(_ group: AgentStatusGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.agent.displayName)
                    .font(.system(size: 15, weight: .semibold))
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
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

                ForEach(detailLines(for: slot), id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                        .lineLimit(1)
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

    private func detailLines(for slot: AgentSessionSlot) -> [String] {
        var details: [String] = []

        if let sessionTitle = slot.sessionTitle, sessionTitle.isEmpty == false {
            details.append(sessionTitle)
        }

        if let projectPath = slot.projectPath, projectPath.isEmpty == false {
            details.append(projectPath)
        }

        return details.isEmpty ? ["Waiting for a session"] : details
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
        switch state {
        case .empty:
            return .appDivider
        case .working:
            return .orange
        case .idle:
            return .green
        case .error:
            return .red
        }
    }
}
