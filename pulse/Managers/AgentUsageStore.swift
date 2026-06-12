import Foundation
import Combine

final class AgentUsageStore: ObservableObject {

    enum LoadError: Error, Equatable, LocalizedError {
        case openCode(OpenCodeUsageQuery.QueryError)
        case codex(CodexUsageQuery.QueryError)

        var errorDescription: String? {
            switch self {
            case .openCode(let error): return error.errorDescription
            case .codex(let error): return error.errorDescription
            }
        }
    }

    @Published private(set) var state: AgentUsageLoadedState
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: LoadError?

    let repository: AgentUsageRepositorying
    let availableSources: [AgentSource]

    private var hasLoadedGeneralData = false

    init(repository: AgentUsageRepositorying? = nil) {
        let defaultRepository = AgentUsageRepository(
            openCodeDatabaseURL: OpenCodeUsageQuery.resolveDatabaseURL(),
            codexDatabaseURL: CodexUsageQuery.resolveDatabaseURL()
        )

        self.repository = repository ?? defaultRepository
        self.state = .empty
        self.availableSources = makeAvailableSources(
            openCodeDatabaseURL: self.repository.openCodeDatabaseURL,
            codexDatabaseURL: self.repository.codexDatabaseURL
        )
    }

    func refreshIfNeeded() {
        guard hasLoadedGeneralData == false else { return }
        refreshAll()
    }

    func refreshAll() {
        if hasLoadedGeneralData == false { isLoading = true } else { isRefreshing = true }

        let nextGeneration = state.refreshGeneration + 1
        let previousState = state
        state = AgentUsageLoadedState(
            openCodeSnapshot: previousState.openCodeSnapshot,
            codexSnapshot: previousState.codexSnapshot,
            refreshGeneration: previousState.refreshGeneration,
            codexDetailCache: [:]
        )

        do {
            let openCodeSnapshot = try repository.loadOpenCodeSnapshot()
            let codexSnapshot = try repository.loadCodexSnapshot()

            state = AgentUsageLoadedState(
                openCodeSnapshot: openCodeSnapshot,
                codexSnapshot: codexSnapshot,
                refreshGeneration: nextGeneration,
                codexDetailCache: [:]
            )

            lastError = nil
            hasLoadedGeneralData = true
        } catch let error as OpenCodeUsageQuery.QueryError {
            lastError = .openCode(error)
        } catch let error as CodexUsageQuery.QueryError {
            lastError = .codex(error)
        } catch {
            lastError = .openCode(.queryStepFailed(message: error.localizedDescription))
        }

        isLoading = false
        isRefreshing = false
    }

    func codexDetail(for threadID: String) -> CodexSessionDetailState {
        state.codexDetailCache[threadID] ?? .idle
    }

    func ensureCodexDetailLoaded(for threadID: String) {
        guard state.codexDetailCache[threadID] == nil || state.codexDetailCache[threadID] == .idle else { return }

        var nextCache = state.codexDetailCache
        nextCache[threadID] = .loading
        state = AgentUsageLoadedState(
            openCodeSnapshot: state.openCodeSnapshot,
            codexSnapshot: state.codexSnapshot,
            refreshGeneration: state.refreshGeneration,
            codexDetailCache: nextCache
        )

        do {
            let detail = try repository.loadCodexDetail(threadID: threadID)
            nextCache[threadID] = .loaded(detail)
        } catch {
            nextCache[threadID] = .failed(error.localizedDescription)
        }

        state = AgentUsageLoadedState(
            openCodeSnapshot: state.openCodeSnapshot,
            codexSnapshot: state.codexSnapshot,
            refreshGeneration: state.refreshGeneration,
            codexDetailCache: nextCache
        )
    }

    func reconcile(_ selection: AgentUsageSelection) -> AgentUsageSelection {
        if selection.source == .all {
            return AgentUsageSelection(
                source: selection.source,
                timeRange: selection.timeRange,
                projectDirectory: selection.projectDirectory,
                sessionID: nil,
                modelGroupBy: selection.modelGroupBy
            )
        }

        guard let projectDirectory = selection.projectDirectory else {
            return AgentUsageSelection(
                source: selection.source,
                timeRange: selection.timeRange,
                projectDirectory: nil,
                sessionID: nil,
                modelGroupBy: selection.modelGroupBy
            )
        }

        return AgentUsageSelection(
            source: selection.source,
            timeRange: selection.timeRange,
            projectDirectory: projectDirectory,
            sessionID: selection.sessionID,
            modelGroupBy: selection.modelGroupBy
        )
    }

    #if DEBUG
    func replaceStateForTesting(_ state: AgentUsageLoadedState) {
        self.state = state
    }
    #endif
}

private func makeAvailableSources(openCodeDatabaseURL: URL, codexDatabaseURL: URL?) -> [AgentSource] {
    var sources: [AgentSource] = []
    var realSources: [AgentSource] = []
    if FileManager.default.fileExists(atPath: openCodeDatabaseURL.path) {
        realSources.append(.openCode)
    }
    if let codexDatabaseURL, FileManager.default.fileExists(atPath: codexDatabaseURL.path) {
        realSources.append(.codex)
    }
    if realSources.isEmpty {
        realSources = [.openCode, .codex]
    }
    if realSources.count >= 2 {
        sources = [.all] + realSources
    } else {
        sources = realSources
    }
    return sources
}
