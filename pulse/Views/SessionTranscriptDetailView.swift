import SwiftUI

struct SessionTranscriptDetailView: View {
    @EnvironmentObject private var store: SessionManagementStore

    var body: some View {
        Group {
            switch store.transcriptState {
            case .idle:
                placeholder(
                    title: "Select a session to view its history",
                    systemImage: "text.bubble"
                )
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading conversation...")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(
                    title: message,
                    systemImage: "exclamationmark.triangle"
                )
            case .loaded(let turns):
                if turns.isEmpty {
                    placeholder(
                        title: "No conversation history available",
                        systemImage: "tray"
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(turns) { turn in
                                transcriptCard(for: turn)
                            }
                        }
                        .padding(16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.35))
    }

    private func placeholder(title: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundColor(.appTertiaryText)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func transcriptCard(for turn: TranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.role.rawValue.capitalized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Text(turn.text)
                .font(.system(size: 13))
                .foregroundColor(.appPrimaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.appFieldBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
