import Combine
import Foundation

struct SessionProjectOption: Identifiable, Equatable {
    let id: String
    let title: String
}

@MainActor
final class SessionManagementStore: ObservableObject {
    @Published private(set) var sessions: [ManagedSessionSummary] = []
    @Published private(set) var selectedSessionID: String?
    @Published var selectedSourceFilter: SessionManagerSourceFilter = .all {
        didSet {
            refreshProjectOptionsForCurrentSource()
        }
    }
    @Published var selectedProjectPath: String? {
        didSet {
            normalizeSelectedProjectPath()
        }
    }
    @Published var searchQuery: String = ""
    @Published private(set) var projectOptions: [SessionProjectOption] = []
    @Published private(set) var transcriptState: TranscriptLoadState = .idle

    private let repository: SessionManagementRepositorying
    private var hasLoaded = false

    init(repository: SessionManagementRepositorying = SessionManagementRepository()) {
        self.repository = repository
    }

    func refreshIfNeeded() {
        guard hasLoaded == false else { return }

        sessions = (try? repository.loadManagedSessions()) ?? []
        refreshProjectOptionsForCurrentSource()
        hasLoaded = true
    }

    var selectedResumeAction: ResumeAction? {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else {
            return nil
        }

        return repository.resumeAction(for: session)
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

    private func buildProjectOptions(from sessions: [ManagedSessionSummary]) -> [SessionProjectOption] {
        var seenPaths = Set<String>()
        var options: [SessionProjectOption] = []

        for session in sessions {
            guard seenPaths.insert(session.projectPath).inserted else { continue }
            options.append(SessionProjectOption(id: session.projectPath, title: session.projectName))
        }

        return options
    }

    private func refreshProjectOptionsForCurrentSource() {
        projectOptions = buildProjectOptions(from: sessionsForCurrentSource())
        normalizeSelectedProjectPath()
    }

    private func sessionsForCurrentSource() -> [ManagedSessionSummary] {
        sessions.filter { session in
            selectedSourceFilter == .all || session.source.rawValue == selectedSourceFilter.rawValue
        }
    }

    private func normalizeSelectedProjectPath() {
        guard let selectedProjectPath else { return }
        guard projectOptions.contains(where: { $0.id == selectedProjectPath }) else {
            self.selectedProjectPath = nil
            return
        }
    }
}
