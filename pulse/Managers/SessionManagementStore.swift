import Combine
import Foundation

@MainActor
final class SessionManagementStore: ObservableObject {
    @Published private(set) var sessions: [ManagedSessionSummary] = []
    @Published private(set) var selectedSessionID: String?
    @Published var selectedSourceFilter: SessionManagerSourceFilter = .all
    @Published var selectedProjectPath: String?
    @Published var searchQuery: String = ""
    @Published private(set) var transcriptState: TranscriptLoadState = .idle

    private let repository: SessionManagementRepositorying
    private var hasLoaded = false

    init(repository: SessionManagementRepositorying = SessionManagementRepository()) {
        self.repository = repository
    }

    func refreshIfNeeded() {
        guard hasLoaded == false else { return }

        sessions = (try? repository.loadManagedSessions()) ?? []
        hasLoaded = true
    }

    func selectSession(id: String?) {
        selectedSessionID = id

        guard let id,
              let session = sessions.first(where: { $0.id == id }) else {
            transcriptState = .idle
            return
        }

        transcriptState = .loading

        do {
            transcriptState = .loaded(try repository.loadTranscript(for: session))
        } catch {
            transcriptState = .failed(error.localizedDescription)
        }
    }

    func visibleSessions() -> [ManagedSessionSummary] {
        sessions.filter { session in
            let sourceMatches =
                selectedSourceFilter == .all ||
                session.source.rawValue == selectedSourceFilter.rawValue
            let projectMatches = selectedProjectPath == nil || session.projectPath == selectedProjectPath
            let searchMatches =
                searchQuery.isEmpty ||
                session.title.localizedCaseInsensitiveContains(searchQuery) ||
                session.projectName.localizedCaseInsensitiveContains(searchQuery) ||
                session.subtitle.localizedCaseInsensitiveContains(searchQuery)

            return sourceMatches && projectMatches && searchMatches
        }
    }
}
