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

    @Published var selectedSource: AgentSource = .openCode

    @Published private(set) var openCodeSnapshot = OpenCodeUsageSnapshot(sessions: [])
    @Published private(set) var codexSnapshot = CodexUsageSnapshot(sessions: [])
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: LoadError?
    @Published private(set) var codexSubagentEdges: [CodexSubagentEdge] = []
    @Published private(set) var codexGoals: [CodexGoal] = []
    @Published private(set) var isLoadingCodexDetail = false

    private(set) var openCodeHasLoaded = false
    private(set) var codexHasLoaded = false

    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?
    let availableSources: [AgentSource]

    init() {
        let openCodeURL = OpenCodeUsageQuery.resolveDatabaseURL()
        self.openCodeDatabaseURL = openCodeURL

        let codexURL = CodexUsageQuery.resolveDatabaseURL()
        self.codexDatabaseURL = codexURL

        var sources: [AgentSource] = []
        if FileManager.default.fileExists(atPath: openCodeURL.path) {
            sources.append(.openCode)
        }
        if let codexURL, FileManager.default.fileExists(atPath: codexURL.path) {
            sources.append(.codex)
        }
        self.availableSources = sources.isEmpty ? [.openCode, .codex] : sources

        if availableSources.contains(.codex) && !availableSources.contains(.openCode) {
            selectedSource = .codex
        }
    }

    func refresh() {
        switch selectedSource {
        case .openCode:
            let firstLoad = openCodeHasLoaded == false
            if firstLoad { isLoading = true } else { isRefreshing = true }

            do {
                openCodeSnapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
                lastError = nil
            } catch let error as OpenCodeUsageQuery.QueryError {
                lastError = .openCode(error)
            } catch {
                lastError = .openCode(.queryStepFailed(message: error.localizedDescription))
            }

            openCodeHasLoaded = true
            isLoading = false
            isRefreshing = false

        case .codex:
            guard let codexDatabaseURL else {
                lastError = .codex(.databaseNotFound(path: "Codex database not found"))
                return
            }

            let firstLoad = codexHasLoaded == false
            if firstLoad { isLoading = true } else { isRefreshing = true }

            do {
                codexSnapshot = try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
                lastError = nil
            } catch let error as CodexUsageQuery.QueryError {
                lastError = .codex(error)
            } catch {
                lastError = .codex(.queryStepFailed(message: error.localizedDescription))
            }

            codexHasLoaded = true
            isLoading = false
            isRefreshing = false
        }
    }

    func refreshIfNeeded() {
        switch selectedSource {
        case .openCode where !openCodeHasLoaded: refresh()
        case .codex where !codexHasLoaded: refresh()
        default: break
        }
    }

    func refreshAll() {
        if FileManager.default.fileExists(atPath: openCodeDatabaseURL.path) {
            let firstLoad = openCodeHasLoaded == false
            if firstLoad && selectedSource == .openCode { isLoading = true }
            else if selectedSource == .openCode { isRefreshing = true }

            do {
                openCodeSnapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
                if selectedSource == .openCode { lastError = nil }
            } catch let error as OpenCodeUsageQuery.QueryError {
                if selectedSource == .openCode { lastError = .openCode(error) }
            } catch {
                if selectedSource == .openCode { lastError = .openCode(.queryStepFailed(message: error.localizedDescription)) }
            }

            openCodeHasLoaded = true
        }

        if let codexDatabaseURL, FileManager.default.fileExists(atPath: codexDatabaseURL.path) {
            let firstLoad = codexHasLoaded == false
            if firstLoad && selectedSource == .codex { isLoading = true }
            else if selectedSource == .codex { isRefreshing = true }

            do {
                codexSnapshot = try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
                if selectedSource == .codex { lastError = nil }
            } catch let error as CodexUsageQuery.QueryError {
                if selectedSource == .codex { lastError = .codex(error) }
            } catch {
                if selectedSource == .codex { lastError = .codex(.queryStepFailed(message: error.localizedDescription)) }
            }

            codexHasLoaded = true
        }

        isLoading = false
        isRefreshing = false
    }

    func loadCodexDetail(for threadID: String) {
        guard let codexDatabaseURL else { return }
        isLoadingCodexDetail = true

        do {
            codexSubagentEdges = try CodexUsageQuery.loadSubagentEdges(databaseURL: codexDatabaseURL, threadID: threadID)
            codexGoals = try CodexUsageQuery.loadGoals(databaseURL: codexDatabaseURL, threadID: threadID)
        } catch {
            codexSubagentEdges = []
            codexGoals = []
        }

        isLoadingCodexDetail = false
    }

    func clearCodexDetail() {
        codexSubagentEdges = []
        codexGoals = []
    }

    var databasePath: String {
        switch selectedSource {
        case .openCode: return openCodeDatabaseURL.path
        case .codex: return codexDatabaseURL?.path ?? "Codex database not found"
        }
    }
}
