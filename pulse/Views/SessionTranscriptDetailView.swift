import SwiftUI
import AppKit

struct SessionTranscriptDetailView: View {
    @EnvironmentObject private var store: SessionManagementStore
    @State private var copiedFeedback: CopyFeedback?
    @State private var lastObservedTranscriptState: TranscriptLoadState = .idle

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let action = store.selectedResumeAction {
                    actionBar(action: action)
                }

                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if shouldShowBusyOverlay {
                busyOverlay
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: copiedFeedback)
        .onAppear {
            DispatchQueue.main.async {
                lastObservedTranscriptState = store.transcriptState
            }
        }
    }

    private var contentArea: some View {
        GeometryReader { geometry in
            Group {
                switch store.transcriptState {
                case .idle:
                    placeholder(
                        title: "Select a session to view its history",
                        systemImage: "text.bubble",
                        size: geometry.size
                    )
                case .loading(let turns):
                    if turns.isEmpty {
                        Color.clear
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        transcriptScrollView(
                            turns: turns,
                            footer: nil,
                            size: geometry.size
                        )
                    }
                case .failed(let message):
                    placeholder(
                        title: message,
                        systemImage: "exclamationmark.triangle",
                        size: geometry.size
                    )
                case .loaded(let turns):
                    if turns.isEmpty {
                        placeholder(
                            title: "No conversation history available",
                            systemImage: "tray",
                            size: geometry.size
                        )
                    } else {
                        transcriptScrollView(turns: turns, footer: nil, size: geometry.size)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }

    private func actionBar(action: ResumeAction) -> some View {
        HStack(spacing: 8) {
            Button("Copy Resume Command") {
                copyToPasteboard(resumeCommand(from: action), feedbackTitle: "Copied Resume Command")
            }

            Button("Copy Context") {
                copyToPasteboard(contextText(), feedbackTitle: "Copied Context")
            }

            Button(store.isRefreshingTranscript ? "Updating..." : "Update") {
                store.refreshSelectedSessionTranscript()
            }
            .disabled(store.isRefreshingTranscript)

            if let copiedFeedback {
                copiedToast(title: copiedFeedback.title)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appSidebarBackground.opacity(0.6))
    }

    private func placeholder(title: String, systemImage: String, size: CGSize) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundColor(.appTertiaryText)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(width: size.width, height: size.height, alignment: .center)
        .padding(24)
        .contentShape(Rectangle())
    }

    private func transcriptScrollView(turns: [TranscriptTurn], footer: AnyView?, size: CGSize) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { turn in
                        chatRow(for: turn)
                    }

                    if let footer {
                        footer
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(transcriptBottomAnchorID)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .onAppear {
                DispatchQueue.main.async {
                    scrollTranscriptToBottom(with: proxy, animated: false)
                }
            }
            .onChange(of: turns.map(\.id)) { _ in
                let currentState = store.transcriptState
                let shouldScroll = SessionTranscriptAutoScroll.shouldScrollToBottom(
                    from: lastObservedTranscriptState,
                    to: currentState
                )
                DispatchQueue.main.async {
                    lastObservedTranscriptState = currentState

                    guard shouldScroll else {
                        return
                    }

                    scrollTranscriptToBottom(with: proxy, animated: true)
                }
            }
        }
    }

    private func chatRow(for turn: TranscriptTurn) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isUser(turn) {
                Spacer(minLength: 48)
                chatBubble(for: turn)
            } else {
                chatBubble(for: turn)
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser(turn) ? .trailing : .leading)
    }

    private func chatBubble(for turn: TranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(displayName(for: turn))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.appSecondaryText)

            Text(turn.text)
                .font(.system(size: 13))
                .foregroundColor(.appPrimaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(bubbleColor(for: turn))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(bubbleBorderColor(for: turn), lineWidth: 1)
        )
    }

    private func isUser(_ turn: TranscriptTurn) -> Bool {
        turn.role == .user
    }

    private func displayName(for turn: TranscriptTurn) -> String {
        switch turn.role {
        case .user:
            return "You"
        case .assistant:
            return assistantDisplayName
        case .system:
            return "System"
        case .unknown:
            return "Message"
        }
    }

    private var assistantDisplayName: String {
        guard let source = store.selectedSessionSource else {
            return "Assistant"
        }

        if source == .openCode {
            return "OpenCode"
        }

        if source == .codex {
            return "Codex"
        }

        return "Assistant"
    }

    private func bubbleColor(for turn: TranscriptTurn) -> Color {
        switch turn.role {
        case .user:
            return Color.blue.opacity(0.16)
        case .assistant:
            return Color(NSColor.systemGray.withAlphaComponent(0.14))
        case .system, .unknown:
            return Color.appSidebarBackground.opacity(0.7)
        }
    }

    private func bubbleBorderColor(for turn: TranscriptTurn) -> Color {
        switch turn.role {
        case .user:
            return Color.blue.opacity(0.24)
        case .assistant, .system, .unknown:
            return Color.appFieldBorder.opacity(0.45)
        }
    }

    private func resumeCommand(from action: ResumeAction) -> String {
        switch action {
        case .openCode(let command), .codex(let command), .claudeCode(let command):
            return command
        }
    }

    private func contextText() -> String {
        guard case .loaded(let turns) = store.transcriptState else { return "" }

        return turns.map { turn in
            "\(displayName(for: turn)): \(turn.text)"
        }
        .joined(separator: "\n\n")
    }

    private func copyToPasteboard(_ text: String, feedbackTitle: String) {
        guard text.isEmpty == false else { return }

        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(text, forType: .string)
        guard copied else { return }

        copiedFeedback = CopyFeedback(title: feedbackTitle)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.copiedFeedback?.title == feedbackTitle else { return }
            self.copiedFeedback = nil
        }
    }

    private func copiedToast(title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.appPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appFieldBackground.opacity(0.96))
            .overlay(
                Capsule()
                    .stroke(Color.appFieldBorder.opacity(0.45), lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
    }

    private var shouldShowBusyOverlay: Bool {
        if store.isRefreshingTranscript {
            return true
        }
        if case .loading = store.transcriptState {
            return true
        }
        return false
    }

    private var busyOverlay: some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.72)
                Text(store.isRefreshingTranscript ? "Updating conversation..." : "Loading conversation...")
                    .font(.system(size: 12))
                    .foregroundColor(.appPrimaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.appFieldBackground.opacity(0.96))
            .overlay(
                Capsule()
                    .stroke(Color.appFieldBorder.opacity(0.42), lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.16))
        .allowsHitTesting(false)
    }

    private func scrollTranscriptToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(transcriptBottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
    }
}

private struct CopyFeedback: Equatable {
    let title: String
}

enum SessionTranscriptAutoScroll {
    static func shouldScrollToBottom(from previous: TranscriptLoadState, to current: TranscriptLoadState) -> Bool {
        let previousTurns = transcriptTurns(in: previous)
        let currentTurns = transcriptTurns(in: current)

        guard currentTurns.isEmpty == false else { return false }
        guard previousTurns != currentTurns else { return false }

        if previousTurns.isEmpty {
            return true
        }

        return previousTurns.last?.id != currentTurns.last?.id
            || previousTurns.count != currentTurns.count
    }

    private static func transcriptTurns(in state: TranscriptLoadState) -> [TranscriptTurn] {
        switch state {
        case .idle, .failed:
            return []
        case .loading(let turns), .loaded(let turns):
            return turns
        }
    }
}

private let transcriptBottomAnchorID = "transcript-bottom-anchor"
