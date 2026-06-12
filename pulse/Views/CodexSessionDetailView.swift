import SwiftUI

struct CodexSessionDetailView: View {
    let session: CodexSessionRecord
    let detailState: CodexSessionDetailState

    var body: some View {
        switch detailState {
        case .idle, .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.appSecondaryText)
        case .loaded(let detail):
            VStack(alignment: .leading, spacing: 12) {
                if detail.edges.isEmpty == false {
                    subagentsSection(edges: detail.edges)
                }
                if detail.goals.isEmpty == false {
                    goalsSection(goals: detail.goals)
                }
            }
        }
    }

    private func subagentsSection(edges: [CodexSubagentEdge]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subagents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            ForEach(edges, id: \.childThreadID) { edge in
                HStack(spacing: 8) {
                    Text("Subagent \(edge.childThreadID.prefix(8))")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)

                    Spacer()

                    Text(edge.status)
                        .font(.system(size: 11))
                        .foregroundColor(.appTertiaryText)
                }
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func goalsSection(goals: [CodexGoal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goals")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            ForEach(goals) { goal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(goal.objective)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)
                            .lineLimit(2)

                        Spacer()

                        goalStatusBadge(goal.status)
                    }

                    if let budget = goal.tokenBudget, budget > 0 {
                        goalProgressView(used: goal.tokensUsed, budget: budget)
                    } else {
                        Text("\(compact(goal.tokensUsed)) tokens used")
                            .font(.system(size: 11))
                            .foregroundColor(.appSecondaryText)
                    }
                }
                .padding(10)
                .background(Color.appFieldBackground.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func goalStatusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(goalStatusColor(status))
            .clipShape(Capsule())
    }

    private func goalStatusColor(_ status: String) -> Color {
        switch status {
        case "active": return .green
        case "paused": return .yellow
        case "budget_limited", "usage_limited": return .red
        case "complete": return .gray
        default: return .gray
        }
    }

    private func goalProgressView(used: Int, budget: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.appTrackBackground)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(
                            width: min(CGFloat(used) / CGFloat(budget), 1.0) * geometry.size.width,
                            height: 6
                        )
                }
            }
            .frame(height: 6)

            Text("\(compact(used)) / \(compact(budget)) tokens")
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1K", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
