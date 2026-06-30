import SwiftUI

struct AgentSourcePicker: View {
    let availableSources: [AgentSource]
    let selectedSource: AgentSource
    let onSelect: (AgentSource) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(availableSources) { source in
                Button {
                    onSelect(source)
                } label: {
                    Text(source.displayName)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .font(.system(size: 12, weight: source == selectedSource ? .semibold : .medium))
                        .foregroundColor(source == selectedSource ? .appPrimaryText : .appSecondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(source == selectedSource ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.appFieldBorder, lineWidth: 1)
        )
    }
}
