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
    @Published var selectedSourceFilter: SessionManagerSourceFilter = .all
    @Published var selectedProjectPath: String?
    @Published var searchQuery: String = ""
    @Published private(set) var projectOptions: [SessionProjectOption] = []
    @Published private(set) var sessionListState: SessionListLoadState = .idle
    @Published private(set) var transcriptState: TranscriptLoadState = .idle
    @Published private(set) var isRefreshingTranscript = false
    @Published private(set) var loadingSources: Set<AgentSource> = []

    private let repository: SessionManagementRepositorying
    private var hasLoaded = false
    private var isLoadingSessions = false
    private var transcriptLoadGeneration = 0

    init(repository: SessionManagementRepositorying = SessionManagementRepository()) {
        self.repository = repository
    }

    func refreshIfNeeded() {
        guard hasLoaded == false else { return }
        refresh()
    }

    func setSelectedSourceFilter(_ sourceFilter: SessionManagerSourceFilter) {
        guard selectedSourceFilter != sourceFilter else { return }
        selectedSourceFilter = sourceFilter
        applyFilterStateChange()
    }

    func setSelectedProjectPath(_ projectPath: String?) {
        let normalizedProjectPath = normalizedProjectPathCandidate(projectPath)
        guard selectedProjectPath != normalizedProjectPath else { return }
        selectedProjectPath = normalizedProjectPath
        reconcileSelectionWithVisibleSessions()
    }

    func setSearchQuery(_ query: String) {
        guard searchQuery != query else { return }
        searchQuery = query
        reconcileSelectionWithVisibleSessions()
    }

    func refresh() {
        guard isLoadingSessions == false else { return }

        isLoadingSessions = true
        sessionListState = .loading
        loadingSources = Set(AgentSource.selectableCases)

        let repository = self.repository
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try repository.loadManagedSessions { update in
                    DispatchQueue.main.async {
                        self.sessions = update.sessions
                        self.refreshProjectOptionsForCurrentSource()
                        self.reconcileSelectionWithVisibleSessions()
                        self.sessionListState = .loading
                        self.loadingSources = Set(AgentSource.selectableCases)
                            .subtracting(update.loadedSources)
                    }
                }
            }
            DispatchQueue.main.async {
                self.isLoadingSessions = false

                switch result {
                case .success(let sessions):
                    self.sessions = sessions
                    self.refreshProjectOptionsForCurrentSource()
                    self.reconcileSelectionWithVisibleSessions()
                    self.sessionListState = .loaded
                    self.loadingSources = []
                    self.hasLoaded = true
                case .failure(let error):
                    self.sessions = []
                    self.projectOptions = []
                    self.selectedProjectPath = nil
                    self.selectSession(id: nil)
                    self.sessionListState = .failed(error.localizedDescription)
                    self.loadingSources = []
                }
            }
        }
    }

    var selectedResumeAction: ResumeAction? {
        guard let session = selectedSession else {
            return nil
        }

        return repository.resumeAction(for: session)
    }

    var selectedSession: ManagedSessionSummary? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    var selectedSessionSource: AgentSource? {
        selectedSession?.source
    }

    func selectSession(id: String?) {
        transcriptLoadGeneration += 1
        selectedSessionID = id
        isRefreshingTranscript = false

        guard let id,
              let session = sessions.first(where: { $0.id == id }) else {
            transcriptState = .idle
            return
        }

        transcriptState = .loading([])
        let generation = transcriptLoadGeneration
        let repository = self.repository

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try repository.loadTranscript(for: session) { partialTurns in
                    DispatchQueue.main.async {
                        guard generation == self.transcriptLoadGeneration,
                              self.selectedSessionID == id else {
                            return
                        }
                        self.transcriptState = .loading(partialTurns)
                    }
                }
            }
            DispatchQueue.main.async {
                guard generation == self.transcriptLoadGeneration,
                      self.selectedSessionID == id else {
                    return
                }

                switch result {
                case .success(let turns):
                    self.transcriptState = .loaded(turns)
                case .failure(let error):
                    self.transcriptState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func refreshSelectedSessionTranscript() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        guard isRefreshingTranscript == false else { return }

        isRefreshingTranscript = true
        let generation = transcriptLoadGeneration
        let repository = self.repository

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try repository.loadTranscript(for: session) }
            DispatchQueue.main.async {
                guard generation == self.transcriptLoadGeneration,
                      self.selectedSessionID == id else {
                    self.isRefreshingTranscript = false
                    return
                }

                self.isRefreshingTranscript = false

                switch result {
                case .success(let turns):
                    self.transcriptState = .loaded(turns)
                case .failure(let error):
                    self.transcriptState = .failed(error.localizedDescription)
                }
            }
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

    func isLoadingSessions(for sourceFilter: SessionManagerSourceFilter) -> Bool {
        switch sourceFilter {
        case .all:
            return sessionListState == .loading
        case .openCode:
            return loadingSources.contains(.openCode)
        case .codex:
            return loadingSources.contains(.codex)
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
        let normalizedProjectPath = normalizedProjectPathCandidate(selectedProjectPath)
        if selectedProjectPath != normalizedProjectPath {
            selectedProjectPath = normalizedProjectPath
        }
    }

    private func sessionsForCurrentSource() -> [ManagedSessionSummary] {
        sessions.filter { session in
            selectedSourceFilter == .all || session.source.rawValue == selectedSourceFilter.rawValue
        }
    }

    private func applyFilterStateChange() {
        refreshProjectOptionsForCurrentSource()
        reconcileSelectionWithVisibleSessions()
    }

    private func normalizedProjectPathCandidate(_ projectPath: String?) -> String? {
        guard let projectPath else { return nil }
        return projectOptions.contains(where: { $0.id == projectPath }) ? projectPath : nil
    }

    private func reconcileSelectionWithVisibleSessions() {
        guard let selectedSessionID else { return }
        guard visibleSessions().contains(where: { $0.id == selectedSessionID }) else {
            selectSession(id: nil)
            return
        }
    }
}
