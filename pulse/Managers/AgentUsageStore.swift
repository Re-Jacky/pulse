import Foundation
import Combine

final class AgentUsageStore: ObservableObject {
    private struct DerivedDataCacheKey: Equatable {
        let selection: AgentUsageSelection
        let refreshGeneration: Int
    }

    private struct RefreshContext {
        let nextGeneration: Int
        let previousState: AgentUsageLoadedState
        let enabledSources: Set<AgentSource>
    }

    private struct RefreshResult {
        let openCodeSnapshot: OpenCodeUsageSnapshot
        let dailyBuckets: [OpenCodeDailyBucket]
        let codexSnapshot: CodexUsageSnapshot
        let codexDailyBuckets: [CodexDailyBucket]
        let refreshGeneration: Int
        let lastError: LoadError?
        let loadedAnySource: Bool
    }

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

    @Published private(set) var availableSources: [AgentSource]

    private var hasLoadedGeneralData = false
    private var derivedDataCache: (key: DerivedDataCacheKey, value: AgentUsageDerivedViewData)?
    private var openCodeBucketsByModelKey: [OpenCodeModelKey: [OpenCodeDailyBucket]] = [:]
    private var codexBucketsBySession: [String: [CodexDailyBucket]] = [:]
    private var ocMetadataByRawID: [String: OpenCodeSessionRecord] = [:]
    private var cxMetadataBySession: [String: CodexSessionRecord] = [:]
    private var ocSessionsByDirectory: [String: [String]] = [:]
    private var cxCSessionsByDirectory: [String: [String]] = [:]
    private let supportedSources: [AgentSource]
    private var enabledSources: Set<AgentSource>

    init(repository: AgentUsageRepositorying? = nil) {
        let defaultRepository = AgentUsageRepository(
            openCodeDatabaseURL: OpenCodeUsageQuery.resolveDatabaseURL(),
            codexDatabaseURL: CodexUsageQuery.resolveDatabaseURL()
        )

        self.repository = repository ?? defaultRepository
        self.state = .empty
        self.supportedSources = makeAvailableSources(
            openCodeDatabaseURL: self.repository.openCodeDatabaseURL,
            codexDatabaseURL: self.repository.codexDatabaseURL
        )
        self.enabledSources = Set(AgentSource.selectableCases)
        self.availableSources = Self.visibleSources(
            supportedSources: self.supportedSources,
            enabledSources: self.enabledSources
        )
    }

    func setEnabledSources(_ sources: Set<AgentSource>) {
        enabledSources = sources.intersection(Set(AgentSource.selectableCases))
        availableSources = Self.visibleSources(
            supportedSources: supportedSources,
            enabledSources: enabledSources
        )
        derivedDataCache = nil
    }

    func refreshIfNeeded() {
        guard hasLoadedGeneralData == false else { return }
        refreshAll()
    }

    func refreshIfNeededAsync() {
        guard hasLoadedGeneralData == false else { return }
        refreshAllAsync()
    }

    func refreshAll() {
        guard let context = beginRefresh() else { return }
        let result = loadRefreshResult(context: context)
        applyRefreshResult(result)
    }

    func refreshAllAsync() {
        guard let context = beginRefresh() else { return }
        let repository = self.repository

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.loadRefreshResult(repository: repository, context: context)
            DispatchQueue.main.async {
                self.applyRefreshResult(result)
            }
        }
    }

    func codexDetail(for threadID: String) -> CodexSessionDetailState {
        state.codexDetailCache[threadID] ?? .idle
    }

    func ensureCodexDetailLoaded(for threadID: String) {
        guard state.codexDetailCache[threadID] == nil || state.codexDetailCache[threadID] == .idle else { return }

        var nextCache = state.codexDetailCache
        nextCache[threadID] = .loading
        state = AgentUsageLoadedState(
            openCodeCumulativeSnapshot: state.openCodeCumulativeSnapshot,
            openCodeDailyBuckets: state.openCodeDailyBuckets,
            codexSnapshot: state.codexSnapshot,
            codexDailyBuckets: state.codexDailyBuckets,
            refreshGeneration: state.refreshGeneration,
            codexDetailCache: nextCache
        )

        do {
            let detail = try repository.loadCodexDetail(
                threadID: threadID,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                fileManager: .default
            )
            nextCache[threadID] = .loaded(detail)
        } catch {
            nextCache[threadID] = .failed(error.localizedDescription)
        }

        state = AgentUsageLoadedState(
            openCodeCumulativeSnapshot: state.openCodeCumulativeSnapshot,
            openCodeDailyBuckets: state.openCodeDailyBuckets,
            codexSnapshot: state.codexSnapshot,
            codexDailyBuckets: state.codexDailyBuckets,
            refreshGeneration: state.refreshGeneration,
            codexDetailCache: nextCache
        )
    }

    func reconcile(_ selection: AgentUsageSelection) -> AgentUsageSelection {
        if selection.source == .all {
            return AgentUsageSelection(
                source: selection.source,
                dateSelection: selection.dateSelection,
                projectDirectory: selection.projectDirectory,
                sessionID: nil,
                modelGroupBy: selection.modelGroupBy
            )
        }

        guard let projectDirectory = selection.projectDirectory else {
            return AgentUsageSelection(
                source: selection.source,
                dateSelection: selection.dateSelection,
                projectDirectory: nil,
                sessionID: nil,
                modelGroupBy: selection.modelGroupBy
            )
        }

        return AgentUsageSelection(
            source: selection.source,
            dateSelection: selection.dateSelection,
            projectDirectory: projectDirectory,
            sessionID: selection.sessionID,
            modelGroupBy: selection.modelGroupBy
        )
    }

    #if DEBUG
    func replaceStateForTesting(_ state: AgentUsageLoadedState) {
        self.state = state
        derivedDataCache = nil
        openCodeBucketsByModelKey = Dictionary(grouping: state.openCodeDailyBuckets) {
            OpenCodeModelKey(sessionID: $0.sessionID, providerID: $0.modelProviderID, modelID: $0.modelID, variant: $0.modelVariant)
        }
        codexBucketsBySession = Dictionary(grouping: state.codexDailyBuckets) { $0.sessionID }
        ocMetadataByRawID = Dictionary(
            state.openCodeCumulativeSnapshot.sessions.map { (rawSessionID(from: $0.id), $0) },
            uniquingKeysWith: { _, last in last }
        )
        cxMetadataBySession = Dictionary(uniqueKeysWithValues: state.codexSnapshot.sessions.map { ($0.id, $0) })
        ocSessionsByDirectory = Dictionary(grouping: state.openCodeCumulativeSnapshot.sessions) { $0.directory }
            .mapValues { $0.map { rawSessionID(from: $0.id) } }
        cxCSessionsByDirectory = Dictionary(grouping: state.codexSnapshot.sessions.filter { $0.isSubagent == false }) { $0.cwd }
            .mapValues { $0.map(\.id) }
    }

    var debugRefreshGenerationForTests: Int {
        state.refreshGeneration
    }
    #endif

    // MARK: - Derivation

    func derivedData(for inputSelection: AgentUsageSelection) -> AgentUsageDerivedViewData {
        let selection = reconcile(inputSelection)
        let cacheKey = DerivedDataCacheKey(selection: selection, refreshGeneration: state.refreshGeneration)
        if let derivedDataCache, derivedDataCache.key == cacheKey {
            return derivedDataCache.value
        }

        let interval = dayInterval(for: selection.dateSelection)

        let openCodeSnapshot: OpenCodeUsageSnapshot
        if state.openCodeDailyBuckets.isEmpty {
            openCodeSnapshot = filteredOpenCodeSnapshot(for: selection.dateSelection, interval: interval)
        } else if interval == nil, let preset = selection.dateSelection.preset {
            openCodeSnapshot = state.openCodeCumulativeSnapshot.filtered(to: preset)
        } else {
            openCodeSnapshot = aggregatedSnapshot(for: selection.dateSelection, interval: interval)
        }
        let codexSnapshot: CodexUsageSnapshot
        if state.codexDailyBuckets.isEmpty {
            codexSnapshot = filteredCodexSnapshot(for: selection.dateSelection, interval: interval)
        } else {
            codexSnapshot = aggregatedCodexSnapshot(for: selection.dateSelection, interval: interval)
        }
        let scope = selection.scope
        let openCodeSessionsByID = Dictionary(uniqueKeysWithValues: openCodeSnapshot.sessions.map { ($0.id, $0) })
        let codexSessionsByID = Dictionary(uniqueKeysWithValues: codexSnapshot.sessions.map { ($0.id, $0) })

        let ocLatestBySession = openCodeLatestActivityBySession(interval: interval, snapshot: openCodeSnapshot)
        let cxLatestBySession = codexLatestActivityBySession(interval: interval, snapshot: codexSnapshot)

        let ocScopeSummary = openCodeSnapshot.summary(for: scope)
        let cxScopeSummary = codexSnapshot.summary(for: scope)
        let ocProjectCount: Int
        let cxProjectCount: Int
        if scope == .allProjects {
            ocProjectCount = Set(openCodeSnapshot.sessions.map(\.directory)).count
            cxProjectCount = Set(codexSnapshot.sessions.filter { $0.isSubagent == false }.map(\.cwd)).count
        } else {
            ocProjectCount = 0
            cxProjectCount = 0
        }

        let summary: AgentUsageSummary = {
            let baseSummary: AgentUsageSummary = switch selection.source {
            case .all:
                AgentUsageSummary.merge(
                    ocScopeSummary,
                    cxScopeSummary
                )
            case .openCode:
                ocScopeSummary
            case .codex:
                cxScopeSummary
            }

            let enrichedRequestCount: Int = {
                switch selection.source {
                case .openCode:
                    return baseSummary.requestCount
                case .codex:
                    return codexRequestCountFromBuckets(for: selection, scope: scope)
                case .all:
                    return baseSummary.requestCount + codexRequestCountFromBuckets(for: selection, scope: scope)

                }
            }()

            let enriched = replacingRequestCount(in: baseSummary, with: enrichedRequestCount)
            return replacingLastUpdated(
                in: enriched,
                with: latestActivityDate(
                    for: selection.source,
                    scope: scope,
                    interval: interval,
                    openCodeSnapshot: openCodeSnapshot,
                    codexSnapshot: codexSnapshot,
                    ocLatestBySession: ocLatestBySession,
                    cxLatestBySession: cxLatestBySession
                )
            )
        }()

        let derivedData = AgentUsageDerivedViewData(
            selection: selection,
            scope: scope,
            summary: summary,
            projectOptions: buildProjectOptions(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            sessionOptions: buildSessionOptions(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession),
            tokenFlowData: buildTokenFlowData(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            usageMetrics: buildUsageMetrics(summary: summary),
            summaryPills: buildSummaryPills(summary: summary),
            contextRows: buildContextRows(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, ocScopeSummary: ocScopeSummary, cxScopeSummary: cxScopeSummary, ocProjectCount: ocProjectCount, cxProjectCount: cxProjectCount, openCodeSessionsByID: openCodeSessionsByID, codexSessionsByID: codexSessionsByID, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession),
            providerBreakdown: buildProviderBreakdown(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            modelBreakdownRows: buildModelBreakdownRows(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            selectedOpenCodeSession: selection.source == .openCode ? normalizedOpenCodeSession(id: selection.sessionID, sessionsByID: openCodeSessionsByID, ocLatestBySession: ocLatestBySession) : nil,
            selectedCodexSession: selection.source == .codex ? normalizedCodexSession(id: selection.sessionID, sessionsByID: codexSessionsByID, cxLatestBySession: cxLatestBySession) : nil,
            codexDetailThreadID: selection.source == .codex && selection.isSessionScope ? selection.sessionID : nil,
            isSessionScope: selection.isSessionScope,
            showsByModel: selection.source != .all && selection.isSessionScope == false,
            showsTokenFlow: selection.source == .all && selection.dateSelection != .preset(.today)
        )

        derivedDataCache = (cacheKey, derivedData)
        return derivedData
    }

    // MARK: - Bucket Aggregation

    private func beginRefresh() -> RefreshContext? {
        guard isLoading == false, isRefreshing == false else { return nil }
        if hasLoadedGeneralData == false { isLoading = true } else { isRefreshing = true }

        let context = RefreshContext(
            nextGeneration: state.refreshGeneration + 1,
            previousState: state,
            enabledSources: enabledSources
        )

        state = AgentUsageLoadedState(
            openCodeCumulativeSnapshot: context.previousState.openCodeCumulativeSnapshot,
            openCodeDailyBuckets: context.previousState.openCodeDailyBuckets,
            codexSnapshot: context.previousState.codexSnapshot,
            codexDailyBuckets: context.previousState.codexDailyBuckets,
            refreshGeneration: context.previousState.refreshGeneration,
            codexDetailCache: [:]
        )

        return context
    }

    private func loadRefreshResult(context: RefreshContext) -> RefreshResult {
        Self.loadRefreshResult(repository: repository, context: context)
    }

    private static func loadRefreshResult(repository: AgentUsageRepositorying, context: RefreshContext) -> RefreshResult {
        var openCodeSnapshot = context.previousState.openCodeCumulativeSnapshot
        var dailyBuckets = context.previousState.openCodeDailyBuckets
        var codexSnapshot = context.previousState.codexSnapshot
        var codexDailyBuckets = context.previousState.codexDailyBuckets
        var firstError: LoadError?
        var loadedAnySource = false

        if context.enabledSources.contains(.openCode) {
            do {
                openCodeSnapshot = try repository.loadOpenCodeCumulativeSnapshot()
                dailyBuckets = try repository.loadOpenCodeDailyBuckets()
                loadedAnySource = true
            } catch let error as OpenCodeUsageQuery.QueryError {
                firstError = .openCode(error)
            } catch {
                firstError = .openCode(.queryStepFailed(message: error.localizedDescription))
            }
        } else {
            openCodeSnapshot = OpenCodeUsageSnapshot(sessions: [])
            dailyBuckets = []
        }

        if context.enabledSources.contains(.codex) {
            do {
                codexSnapshot = try repository.loadCodexSnapshot()
                codexDailyBuckets = try repository.loadCodexDailyBuckets()
                loadedAnySource = true
            } catch let error as CodexUsageQuery.QueryError {
                if firstError == nil { firstError = .codex(error) }
            } catch {
                if firstError == nil {
                    firstError = .codex(.queryStepFailed(message: error.localizedDescription))
                }
            }
        } else {
            codexSnapshot = CodexUsageSnapshot(sessions: [])
            codexDailyBuckets = []
        }

        return RefreshResult(
            openCodeSnapshot: openCodeSnapshot,
            dailyBuckets: dailyBuckets,
            codexSnapshot: codexSnapshot,
            codexDailyBuckets: codexDailyBuckets,
            refreshGeneration: loadedAnySource ? context.nextGeneration : context.previousState.refreshGeneration,
            lastError: firstError,
            loadedAnySource: loadedAnySource
        )
    }

    private func applyRefreshResult(_ result: RefreshResult) {
        state = AgentUsageLoadedState(
            openCodeCumulativeSnapshot: result.openCodeSnapshot,
            openCodeDailyBuckets: result.dailyBuckets,
            codexSnapshot: result.codexSnapshot,
            codexDailyBuckets: result.codexDailyBuckets,
            refreshGeneration: result.refreshGeneration,
            codexDetailCache: [:]
        )
        derivedDataCache = nil
        openCodeBucketsByModelKey = Dictionary(grouping: result.dailyBuckets) {
            OpenCodeModelKey(sessionID: $0.sessionID, providerID: $0.modelProviderID, modelID: $0.modelID, variant: $0.modelVariant)
        }
        codexBucketsBySession = Dictionary(grouping: result.codexDailyBuckets) { $0.sessionID }
        ocMetadataByRawID = Dictionary(
            result.openCodeSnapshot.sessions.map { (rawSessionID(from: $0.id), $0) },
            uniquingKeysWith: { _, last in last }
        )
        cxMetadataBySession = Dictionary(uniqueKeysWithValues: result.codexSnapshot.sessions.map { ($0.id, $0) })
        ocSessionsByDirectory = Dictionary(grouping: result.openCodeSnapshot.sessions) { $0.directory }
            .mapValues { $0.map { rawSessionID(from: $0.id) } }
        cxCSessionsByDirectory = Dictionary(grouping: result.codexSnapshot.sessions.filter { $0.isSubagent == false }) { $0.cwd }
            .mapValues { $0.map(\.id) }

        lastError = result.lastError
        if result.loadedAnySource {
            hasLoadedGeneralData = true
        }

        isLoading = false
        isRefreshing = false
    }

    private func aggregatedSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> OpenCodeUsageSnapshot {
        guard let interval else {
            if let preset = selection.preset {
                return state.openCodeCumulativeSnapshot.filtered(to: preset)
            }
            return state.openCodeCumulativeSnapshot
        }

        let records: [OpenCodeSessionRecord] = openCodeBucketsByModelKey.compactMap { key, buckets in
            guard let m = ocMetadataByRawID[key.sessionID] else { return nil }

            var input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0, requests = 0
            var cost = 0.0
            var updatedAt: Date?
            var hasInRangeBuckets = false
            for b in buckets {
                guard interval.contains(b.day) else { continue }
                hasInRangeBuckets = true
                input += b.inputTokens; output += b.outputTokens; reasoning += b.reasoningTokens
                cacheRead += b.cacheReadTokens; cacheWrite += b.cacheWriteTokens; requests += b.requestCount
                cost += b.cost
                let activityAt = b.latestActivityAt ?? approximateOpenCodeActivityDate(for: b.day, relativeTo: m.updatedAt)
                if updatedAt == nil || activityAt > updatedAt! { updatedAt = activityAt }
            }

            guard hasInRangeBuckets else { return nil }

            let compoundID = [key.sessionID, key.providerID, key.modelID, key.variant ?? ""].joined(separator: "::")

            return OpenCodeSessionRecord(
                id: compoundID,
                title: m.title,
                directory: m.directory,
                agent: m.agent,
                modelProviderID: key.providerID,
                modelID: key.modelID,
                modelVariant: key.variant,
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                requestCount: requests,
                cost: cost,
                createdAt: m.createdAt,
                updatedAt: updatedAt ?? m.updatedAt
            )
        }

        return OpenCodeUsageSnapshot(sessions: records)
    }

    private func aggregatedCodexSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> CodexUsageSnapshot {
        guard let interval else {
            if let preset = selection.preset {
                return state.codexSnapshot.filtered(to: preset)
            }
            return state.codexSnapshot
        }

        let records: [CodexSessionRecord] = codexBucketsBySession.compactMap { sessionID, buckets in
            guard let session = cxMetadataBySession[sessionID] else { return nil }

            var maxActivity: Date?
            var totalTokens = 0, input = 0, output = 0, reasoning = 0, cacheRead = 0
            var hasInRangeBuckets = false
            for b in buckets {
                guard interval.contains(b.day) else { continue }
                hasInRangeBuckets = true
                totalTokens += b.totalTokens; input += b.inputTokens; output += b.outputTokens
                reasoning += b.reasoningTokens; cacheRead += b.cacheReadTokens
                let d = b.latestActivityAt ?? approximateCodexActivityDate(for: b.day, relativeTo: session.updatedAt)
                if maxActivity == nil || d > maxActivity! { maxActivity = d }
            }

            guard hasInRangeBuckets else { return nil }

            let updatedAt = maxActivity ?? session.updatedAt

            return CodexSessionRecord(
                id: session.id,
                title: session.title,
                cwd: session.cwd,
                model: session.model,
                modelProvider: session.modelProvider,
                tokensUsed: totalTokens,
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning,
                cacheReadTokens: cacheRead,
                reasoningEffort: session.reasoningEffort,
                threadSource: session.threadSource,
                agentNickname: session.agentNickname,
                agentRole: session.agentRole,
                createdAt: session.createdAt,
                updatedAt: updatedAt
            )
        }

        return CodexUsageSnapshot(sessions: records)
    }

    private func dayInterval(for selection: AgentDateSelection) -> Range<Int>? {
        agentUsageDayInterval(for: selection)
    }

    private func filteredOpenCodeSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> OpenCodeUsageSnapshot {
        if let preset = selection.preset, interval == nil {
            return state.openCodeCumulativeSnapshot.filtered(to: preset)
        }
        guard let interval else { return state.openCodeCumulativeSnapshot }
        let sessions = state.openCodeCumulativeSnapshot.sessions.filter {
            interval.contains(agentUsageDayIdentifier(for: $0.updatedAt))
        }
        return OpenCodeUsageSnapshot(sessions: sessions)
    }

    private func filteredCodexSnapshot(for selection: AgentDateSelection, interval: Range<Int>?) -> CodexUsageSnapshot {
        if let preset = selection.preset, interval == nil {
            return state.codexSnapshot.filtered(to: preset)
        }
        guard let interval else { return state.codexSnapshot }
        let sessions = state.codexSnapshot.sessions.filter {
            interval.contains(agentUsageDayIdentifier(for: $0.updatedAt))
        }
        return CodexUsageSnapshot(sessions: sessions)
    }

    private func approximateOpenCodeActivityDate(for day: Int, relativeTo reference: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let referenceDay = agentUsageDayIdentifier(for: reference, calendar: calendar)
        let deltaDays = day - referenceDay
        return calendar.date(byAdding: .day, value: deltaDays, to: reference) ?? reference
    }

    private func approximateCodexActivityDate(for day: Int, relativeTo reference: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let referenceDay = agentUsageDayIdentifier(for: reference, calendar: calendar)
        let deltaDays = day - referenceDay
        return calendar.date(byAdding: .day, value: deltaDays, to: reference) ?? reference
    }

    // MARK: - Derivation Helpers

    private func buildProjectOptions(selection: AgentUsageSelection, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [SearchableSelectorOption] {
        switch selection.source {
        case .all:
            let ocProjects = Dictionary(grouping: openCodeSnapshot.sessions, by: \.directory)
            let cxProjects = Dictionary(grouping: codexSnapshot.sessions.filter { $0.isSubagent == false }, by: \.cwd)
            let allDirs = Set(ocProjects.keys).union(cxProjects.keys)
            let sorted: [(option: SearchableSelectorOption, tokens: Int)] = allDirs.map { dir in
                let ocSessions = ocProjects[dir] ?? []
                let cxSessions = cxProjects[dir] ?? []
                let totalTokens = ocSessions.reduce(0) { $0 + $1.totalTokens } + cxSessions.reduce(0) { $0 + $1.tokensUsed }
                let sessionsCount = ocSessions.count + cxSessions.count
                let option = SearchableSelectorOption(
                    id: dir,
                    title: URL(fileURLWithPath: dir).lastPathComponent,
                    subtitle: "\(compact(totalTokens)) total tokens \u{2022} \(sessionsCount) sessions \u{2022} \(dir)"
                )
                return (option, totalTokens)
            }
            .sorted { lhs, rhs in
                if lhs.tokens == rhs.tokens {
                    return lhs.option.title.localizedCaseInsensitiveCompare(rhs.option.title) == .orderedAscending
                }
                return lhs.tokens > rhs.tokens
            }
            return sorted.map { $0.option }
        case .openCode:
            return openCodeSnapshot.projectOptions.map {
                SearchableSelectorOption(
                    id: $0.directory,
                    title: $0.shortName,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
                )
            }
        case .codex:
            return codexSnapshot.projectOptions.map {
                SearchableSelectorOption(
                    id: $0.directory,
                    title: $0.shortName,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
                )
            }
        }
    }

    private func buildSessionOptions(selection: AgentUsageSelection, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot, ocLatestBySession: [String: Date], cxLatestBySession: [String: Date]) -> [SearchableSelectorOption] {
        switch selection.source {
        case .all:
            return []
        case .openCode:
            guard let projectDirectory = selection.projectDirectory else { return [] }
            return openCodeSnapshot.sessionOptions(for: projectDirectory).map {
                let updatedAt = ocLatestBySession[rawSessionID(from: $0.id)] ?? $0.updatedAt
                return SearchableSelectorOption(
                    id: $0.id,
                    title: $0.title,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime(updatedAt)) \u{2022} \($0.modelDisplayName)"
                )
            }
        case .codex:
            guard let projectDirectory = selection.projectDirectory else { return [] }
            return codexSnapshot.sessionOptions(for: projectDirectory).map {
                let updatedAt = cxLatestBySession[$0.id] ?? $0.updatedAt
                let effort = $0.reasoningEffort.isEmpty ? "" : " \u{2022} \($0.reasoningEffort)"
                return SearchableSelectorOption(
                    id: $0.id,
                    title: $0.title,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime(updatedAt)) \u{2022} \($0.modelDisplayName)\(effort)"
                )
            }
        }
    }

    private func buildTokenFlowData(selection: AgentUsageSelection, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [TokenUsageDataPoint] {
        guard selection.source == .all, selection.dateSelection != .preset(.today) else { return [] }

        let interval = dayInterval(for: selection.dateSelection)

        let openCodeTotals = openCodeTokenFlowTotals(
            interval: interval,
            snapshot: openCodeSnapshot
        )
        let codexTotals = codexTokenFlowTotals(
            interval: interval,
            snapshot: codexSnapshot
        )

        guard openCodeTotals.isEmpty == false || codexTotals.isEmpty == false else { return [] }

        var totalsByDay = openCodeTotals
        for (day, value) in codexTotals {
            totalsByDay[day, default: 0] += value
        }

        guard let earliestDay = totalsByDay.keys.min(), let latestDay = totalsByDay.keys.max() else { return [] }

        let totalDays = max(1, latestDay - earliestDay + 1)
        let bucketSize: Int
        if selection.dateSelection == .preset(.allTime) {
            bucketSize = max(1, Int(ceil(Double(totalDays) / 30)))
        } else {
            bucketSize = 1
        }

        let sortedDays = totalsByDay.keys.sorted()

        var buckets: [TokenUsageDataPoint] = []
        var cursor = earliestDay
        var si = 0
        while cursor <= latestDay {
            let bucketEnd = cursor + bucketSize
            var sum = 0
            while si < sortedDays.count, sortedDays[si] < bucketEnd {
                guard sortedDays[si] >= cursor else { si += 1; continue }
                sum += totalsByDay[sortedDays[si]]!
                si += 1
            }
            let date = Date(timeIntervalSince1970: Double(cursor * 86_400_000) / 1000)
            buckets.append(TokenUsageDataPoint(date: date, totalTokens: sum, bucketSizeDays: bucketSize))
            cursor = bucketEnd
        }
        return buckets
    }

    private func openCodeTokenFlowTotals(
        interval: Range<Int>?,
        snapshot: OpenCodeUsageSnapshot
    ) -> [Int: Int] {
        if state.openCodeDailyBuckets.isEmpty == false && snapshot.sessions.isEmpty == false {
            var totals: [Int: Int] = [:]
            for (_, buckets) in openCodeBucketsByModelKey {
                for bucket in buckets {
                    guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
                    let value = bucket.inputTokens + bucket.outputTokens + bucket.reasoningTokens + bucket.cacheReadTokens + bucket.cacheWriteTokens
                    totals[bucket.day, default: 0] += value
                }
            }
            return totals
        }

        return snapshot.sessions.reduce(into: [:]) { totals, session in
            let day = agentUsageDayIdentifier(for: session.updatedAt)
            totals[day, default: 0] += session.totalTokens
        }
    }

    private func codexTokenFlowTotals(
        interval: Range<Int>?,
        snapshot: CodexUsageSnapshot
    ) -> [Int: Int] {
        if state.codexDailyBuckets.isEmpty == false && snapshot.sessions.isEmpty == false {
            var totals: [Int: Int] = [:]
            for (_, buckets) in codexBucketsBySession {
                for bucket in buckets {
                    guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
                    totals[bucket.day, default: 0] += bucket.totalTokens
                }
            }
            return totals
        }

        return snapshot.sessions.reduce(into: [:]) { totals, session in
            let day = agentUsageDayIdentifier(for: session.updatedAt)
            totals[day, default: 0] += session.tokensUsed
        }
    }

    private func buildUsageMetrics(summary: AgentUsageSummary) -> [AgentUsageMetricCard] {
        var metrics: [AgentUsageMetricCard] = [
            AgentUsageMetricCard(id: "total", title: "Total", valueText: compact(summary.totalTokens), detailText: nil)
        ]
        if let input = summary.inputTokens {
            metrics.append(AgentUsageMetricCard(id: "input", title: "Input", valueText: compact(input), detailText: nil))
        }
        if let output = summary.outputTokens {
            metrics.append(AgentUsageMetricCard(id: "output", title: "Output", valueText: compact(output), detailText: nil))
        }
        if let cacheRead = summary.cacheReadTokens {
            metrics.append(AgentUsageMetricCard(id: "cacheRead", title: "Cache Read", valueText: compact(cacheRead), detailText: nil))
        }
        if summary.requestCount > 0 {
            metrics.append(AgentUsageMetricCard(id: "requests", title: "Requests", valueText: compact(summary.requestCount), detailText: nil))
        }
        return metrics
    }

    private func buildSummaryPills(summary: AgentUsageSummary) -> [AgentUsageSummaryPill] {
        var pills: [AgentUsageSummaryPill] = []
        if let reasoning = summary.reasoningTokens {
            pills.append(AgentUsageSummaryPill(id: "reasoning", title: "Reasoning", valueText: compact(reasoning)))
        }
        if let cacheWrite = summary.cacheWriteTokens {
            pills.append(AgentUsageSummaryPill(id: "cacheWrite", title: "Cache Write", valueText: compact(cacheWrite)))
        }
        if let cacheRead = summary.cacheReadTokens, let input = summary.inputTokens {
            let totalInput = input + cacheRead
            if totalInput > 0 {
                let rate = Double(cacheRead) / Double(totalInput)
                pills.append(AgentUsageSummaryPill(id: "hitRate", title: "Hit Rate", valueText: String(format: "%.0f%%", rate * 100)))
            }
        }
        pills.append(AgentUsageSummaryPill(id: "sessions", title: "Sessions", valueText: "\(summary.sessionsCount)"))
        pills.append(AgentUsageSummaryPill(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-"))
        if let cost = summary.cost, cost > 0 {
            pills.append(AgentUsageSummaryPill(id: "cost", title: "Cost", valueText: String(format: "$%.2f", cost)))
        }
        return pills
    }

    private func buildContextRows(selection: AgentUsageSelection, scope: AgentScope, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot, ocScopeSummary: AgentUsageSummary, cxScopeSummary: AgentUsageSummary, ocProjectCount: Int, cxProjectCount: Int, openCodeSessionsByID: [String: OpenCodeSessionRecord], codexSessionsByID: [String: CodexSessionRecord], ocLatestBySession: [String: Date], cxLatestBySession: [String: Date]) -> [AgentUsageDetailRow] {
        guard selection.source != .all else { return [] }

        var rows: [AgentUsageDetailRow] = []

        switch selection.source {
        case .all:
            break
        case .openCode:
            let summary = replacingLastUpdated(
                in: ocScopeSummary,
                with: latestActivityDate(
                    for: .openCode,
                    scope: scope,
                    interval: dayInterval(for: selection.dateSelection),
                    openCodeSnapshot: openCodeSnapshot,
                    codexSnapshot: codexSnapshot,
                    ocLatestBySession: ocLatestBySession,
                    cxLatestBySession: cxLatestBySession
                )
            )
            switch scope {
            case .allProjects:
                rows.append(AgentUsageDetailRow(id: "projectsCount", title: "Projects Count", valueText: "\(ocProjectCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .project(let directory):
                rows.append(AgentUsageDetailRow(id: "projectName", title: "Project Name", valueText: URL(fileURLWithPath: directory).lastPathComponent, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: directory, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .session:
                let session = selection.sessionID.flatMap { openCodeSessionsByID[$0] }
                let rawID = selection.sessionID.map { rawSessionID(from: $0) }
                let updatedAt = rawID.flatMap { ocLatestBySession[$0] } ?? session?.updatedAt
                rows.append(AgentUsageDetailRow(id: "title", title: "Title", valueText: session?.title ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: session?.directory ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "agent", title: "Agent", valueText: session?.agent ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "providerModel", title: "Provider / Model", valueText: session.map { OpenCodeUsageSnapshot.modelDisplayName(providerID: $0.modelProviderID, modelID: $0.modelID, variant: $0.modelVariant) } ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "created", title: "Created", valueText: session.map { shortDateTime($0.createdAt) } ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: updatedAt.map(shortDateTime) ?? "-", secondaryText: nil))
            }
        case .codex:
            let summary = replacingLastUpdated(
                in: cxScopeSummary,
                with: latestActivityDate(
                    for: .codex,
                    scope: scope,
                    interval: dayInterval(for: selection.dateSelection),
                    openCodeSnapshot: openCodeSnapshot,
                    codexSnapshot: codexSnapshot,
                    ocLatestBySession: ocLatestBySession,
                    cxLatestBySession: cxLatestBySession
                )
            )
            switch scope {
            case .allProjects:
                rows.append(AgentUsageDetailRow(id: "projectsCount", title: "Projects Count", valueText: "\(cxProjectCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .project(let directory):
                rows.append(AgentUsageDetailRow(id: "projectName", title: "Project Name", valueText: URL(fileURLWithPath: directory).lastPathComponent, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: directory, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .session:
                let session = selection.sessionID.flatMap { codexSessionsByID[$0] }
                let updatedAt = selection.sessionID.flatMap { cxLatestBySession[$0] } ?? session?.updatedAt
                rows.append(AgentUsageDetailRow(id: "title", title: "Title", valueText: session?.title ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: session?.cwd ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "model", title: "Model", valueText: session.map { "\($0.modelProvider) / \($0.model)" } ?? "-", secondaryText: nil))
                if let session, session.reasoningEffort.isEmpty == false {
                    rows.append(AgentUsageDetailRow(id: "reasoningEffort", title: "Reasoning Effort", valueText: session.reasoningEffort, secondaryText: nil))
                }
                rows.append(AgentUsageDetailRow(id: "created", title: "Created", valueText: session.map { shortDateTime($0.createdAt) } ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: updatedAt.map(shortDateTime) ?? "-", secondaryText: nil))
            }
        }
        return rows
    }

    private func replacingRequestCount(in summary: AgentUsageSummary, with requestCount: Int) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: summary.totalTokens,
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            reasoningTokens: summary.reasoningTokens,
            cacheReadTokens: summary.cacheReadTokens,
            cacheWriteTokens: summary.cacheWriteTokens,
            requestCount: requestCount,
            sessionsCount: summary.sessionsCount,
            cost: summary.cost,
            lastUpdated: summary.lastUpdated
        )
    }

    private func codexRequestCountFromBuckets(
        for selection: AgentUsageSelection,
        scope: AgentScope
    ) -> Int {
        guard selection.source == .codex || selection.source == .all else { return 0 }
        let interval = dayInterval(for: selection.dateSelection)

        switch scope {
        case .allProjects:
            return codexBucketsBySession.reduce(0) { total, entry in
                guard cxMetadataBySession[entry.key]?.isSubagent == false else { return total }
                var requestCount = 0
                for bucket in entry.value where interval.map({ $0.contains(bucket.day) }) ?? true {
                    requestCount += bucket.requestCount
                }
                return total + requestCount
            }
        case .project(let directory):
            let sessionIDs = Set(cxCSessionsByDirectory[directory] ?? [])
            return codexBucketsBySession.reduce(0) { total, entry in
                guard sessionIDs.contains(entry.key) else { return total }
                var requestCount = 0
                for bucket in entry.value where interval.map({ $0.contains(bucket.day) }) ?? true {
                    requestCount += bucket.requestCount
                }
                return total + requestCount
            }
        case .session(_, let sessionID):
            guard let buckets = codexBucketsBySession[sessionID] else { return 0 }
            var requestCount = 0
            for bucket in buckets where interval.map({ $0.contains(bucket.day) }) ?? true {
                requestCount += bucket.requestCount
            }
            return requestCount
        }
    }

    private func replacingLastUpdated(in summary: AgentUsageSummary, with lastUpdated: Date?) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: summary.totalTokens,
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            reasoningTokens: summary.reasoningTokens,
            cacheReadTokens: summary.cacheReadTokens,
            cacheWriteTokens: summary.cacheWriteTokens,
            requestCount: summary.requestCount,
            sessionsCount: summary.sessionsCount,
            cost: summary.cost,
            lastUpdated: lastUpdated ?? summary.lastUpdated
        )
    }

    private func rawSessionID(from compoundID: String) -> String {
        compoundID.components(separatedBy: "::").first ?? compoundID
    }

    private func latestActivityDate(
        for source: AgentSource,
        scope: AgentScope,
        interval: Range<Int>?,
        openCodeSnapshot: OpenCodeUsageSnapshot,
        codexSnapshot: CodexUsageSnapshot,
        ocLatestBySession: [String: Date],
        cxLatestBySession: [String: Date]
    ) -> Date? {
        switch source {
        case .all:
            return [
                latestActivityDate(for: .openCode, scope: scope, interval: interval, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession),
                latestActivityDate(for: .codex, scope: scope, interval: interval, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot, ocLatestBySession: ocLatestBySession, cxLatestBySession: cxLatestBySession)
            ].compactMap { $0 }.max()
        case .openCode:
            switch scope {
            case .allProjects:
                return ocLatestBySession.values.max() ?? openCodeSnapshot.summary(for: scope).lastUpdated
            case .project(let directory):
                var maxDate: Date?
                for rawID in ocSessionsByDirectory[directory] ?? [] {
                    let activityAt = ocLatestBySession[rawID] ?? ocMetadataByRawID[rawID]?.updatedAt ?? .distantPast
                    if maxDate == nil || activityAt > maxDate! { maxDate = activityAt }
                }
                return maxDate ?? openCodeSnapshot.summary(for: scope).lastUpdated
            case .session(_, let sessionID):
                return ocLatestBySession[rawSessionID(from: sessionID)] ?? openCodeSnapshot.summary(for: scope).lastUpdated
            }
        case .codex:
            switch scope {
            case .allProjects:
                var maxDate: Date?
                for (sessionID, activityAt) in cxLatestBySession {
                    guard cxMetadataBySession[sessionID]?.isSubagent == false else { continue }
                    if maxDate == nil || activityAt > maxDate! { maxDate = activityAt }
                }
                return maxDate ?? codexSnapshot.summary(for: scope).lastUpdated
            case .project(let directory):
                var maxDate: Date?
                for sessionID in cxCSessionsByDirectory[directory] ?? [] {
                    let activityAt = cxLatestBySession[sessionID] ?? cxMetadataBySession[sessionID]?.updatedAt ?? .distantPast
                    if maxDate == nil || activityAt > maxDate! { maxDate = activityAt }
                }
                return maxDate ?? codexSnapshot.summary(for: scope).lastUpdated
            case .session(_, let sessionID):
                return cxLatestBySession[sessionID] ?? codexSnapshot.summary(for: scope).lastUpdated
            }
        }
    }

    private func openCodeLatestActivityBySession(
        interval: Range<Int>?,
        snapshot: OpenCodeUsageSnapshot
    ) -> [String: Date] {
        var result: [String: Date] = [:]
        for (key, buckets) in openCodeBucketsByModelKey {
            guard let metadata = ocMetadataByRawID[key.sessionID] else { continue }
            for bucket in buckets {
                guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
                let activityAt = bucket.latestActivityAt ?? approximateOpenCodeActivityDate(for: bucket.day, relativeTo: metadata.updatedAt)
                result[key.sessionID] = max(result[key.sessionID] ?? .distantPast, activityAt)
            }
        }
        return result
    }

    private func codexLatestActivityBySession(
        interval: Range<Int>?,
        snapshot: CodexUsageSnapshot
    ) -> [String: Date] {
        var result: [String: Date] = [:]
        for (sessionID, buckets) in codexBucketsBySession {
            guard let metadata = cxMetadataBySession[sessionID] else { continue }
            for bucket in buckets {
                guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
                let activityAt = bucket.latestActivityAt ?? approximateCodexActivityDate(for: bucket.day, relativeTo: metadata.updatedAt)
                result[sessionID] = max(result[sessionID] ?? .distantPast, activityAt)
            }
        }
        return result
    }

    private func normalizedOpenCodeSession(
        id: String?,
        sessionsByID: [String: OpenCodeSessionRecord],
        ocLatestBySession: [String: Date]
    ) -> OpenCodeSessionRecord? {
        guard let id, let session = sessionsByID[id] else { return nil }
        guard let updatedAt = ocLatestBySession[rawSessionID(from: id)] else { return session }

        return OpenCodeSessionRecord(
            id: session.id,
            title: session.title,
            directory: session.directory,
            agent: session.agent,
            modelProviderID: session.modelProviderID,
            modelID: session.modelID,
            modelVariant: session.modelVariant,
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            reasoningTokens: session.reasoningTokens,
            cacheReadTokens: session.cacheReadTokens,
            cacheWriteTokens: session.cacheWriteTokens,
            requestCount: session.requestCount,
            cost: session.cost,
            createdAt: session.createdAt,
            updatedAt: updatedAt
        )
    }

    private func normalizedCodexSession(
        id: String?,
        sessionsByID: [String: CodexSessionRecord],
        cxLatestBySession: [String: Date]
    ) -> CodexSessionRecord? {
        guard let id, let session = sessionsByID[id] else { return nil }
        guard let updatedAt = cxLatestBySession[id] else { return session }

        return CodexSessionRecord(
            id: session.id,
            title: session.title,
            cwd: session.cwd,
            model: session.model,
            modelProvider: session.modelProvider,
            tokensUsed: session.tokensUsed,
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            reasoningTokens: session.reasoningTokens,
            cacheReadTokens: session.cacheReadTokens,
            reasoningEffort: session.reasoningEffort,
            threadSource: session.threadSource,
            agentNickname: session.agentNickname,
            agentRole: session.agentRole,
            createdAt: session.createdAt,
            updatedAt: updatedAt
        )
    }

    private func buildProviderBreakdown(selection: AgentUsageSelection, scope: AgentScope, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [ProviderBreakdown] {
        guard selection.source != .all else { return [] }
        switch selection.source {
        case .all: return []
        case .openCode:
            if selection.dateSelection == .preset(.allTime) {
                return openCodeSnapshot.providerBreakdown(for: scope)
            }
            return openCodeProviderBreakdown(for: scope, interval: dayInterval(for: selection.dateSelection))
        case .codex: return codexSnapshot.providerBreakdown(for: scope)
        }
    }

    private func buildModelBreakdownRows(selection: AgentUsageSelection, scope: AgentScope, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [AgentUsageDetailRow] {
        guard selection.source != .all else { return [] }
        switch selection.source {
        case .all: return []
        case .openCode:
            let rows: [OpenCodeModelBreakdown]
            if selection.dateSelection == .preset(.allTime) {
                rows = openCodeSnapshot.modelBreakdown(for: scope)
            } else {
                rows = openCodeModelBreakdown(for: scope, interval: dayInterval(for: selection.dateSelection))
            }
            return rows.map {
                AgentUsageDetailRow(
                    id: $0.id,
                    title: OpenCodeUsageSnapshot.modelDisplayName(providerID: $0.providerID, modelID: $0.modelID, variant: $0.variant),
                    valueText: compact($0.summary.totalTokens),
                    secondaryText: nil
                )
            }
        case .codex:
            return codexSnapshot.modelBreakdown(for: scope).map {
                AgentUsageDetailRow(
                    id: "\($0.modelProvider)/\($0.model)",
                    title: "\($0.modelProvider) / \($0.model)",
                    valueText: compact($0.summary.totalTokens),
                    secondaryText: nil
                )
            }
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func openCodeBuckets(for scope: AgentScope, interval: Range<Int>?) -> [OpenCodeDailyBucket] {
        var result: [OpenCodeDailyBucket] = []
        for (key, buckets) in openCodeBucketsByModelKey {
            switch scope {
            case .allProjects:
                break
            case .project(let directory):
                guard ocMetadataByRawID[key.sessionID]?.directory == directory else { continue }
            case .session(_, let sessionID):
                guard key.sessionID == rawSessionID(from: sessionID) else { continue }
            }
            for bucket in buckets {
                guard interval.map({ $0.contains(bucket.day) }) ?? true else { continue }
                result.append(bucket)
            }
        }
        return result
    }

    private func openCodeProviderBreakdown(for scope: AgentScope, interval: Range<Int>?) -> [ProviderBreakdown] {
        Dictionary(grouping: openCodeBuckets(for: scope, interval: interval)) { $0.modelProviderID }
            .map { provider, buckets in
                ProviderBreakdown(
                    provider: provider,
                    summary: openCodeBucketSummary(from: buckets)
                )
            }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    private func openCodeModelBreakdown(for scope: AgentScope, interval: Range<Int>?) -> [OpenCodeModelBreakdown] {
        Dictionary(grouping: openCodeBuckets(for: scope, interval: interval)) {
            [$0.modelProviderID, $0.modelID, $0.modelVariant ?? ""].joined(separator: "::")
        }
        .compactMap { _, buckets in
            guard let first = buckets.first else { return nil }
            return OpenCodeModelBreakdown(
                providerID: first.modelProviderID,
                modelID: first.modelID,
                variant: first.modelVariant,
                summary: openCodeBucketSummary(from: buckets)
            )
        }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
    }

    private func openCodeBucketSummary(from buckets: [OpenCodeDailyBucket]) -> AgentUsageSummary {
        var totalTokens = 0, input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0, requests = 0
        var cost = 0.0
        var sessionIDs = Set<String>()
        var lastUpdated: Date?
        for b in buckets {
            input += b.inputTokens; output += b.outputTokens; reasoning += b.reasoningTokens
            cacheRead += b.cacheReadTokens; cacheWrite += b.cacheWriteTokens; requests += b.requestCount
            cost += b.cost; sessionIDs.insert(b.sessionID)
            if let a = b.latestActivityAt, lastUpdated == nil || a > lastUpdated! { lastUpdated = a }
        }
        totalTokens = input + output + reasoning + cacheRead + cacheWrite
        return AgentUsageSummary(
            totalTokens: totalTokens,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            requestCount: requests,
            sessionsCount: sessionIDs.count,
            cost: cost,
            lastUpdated: lastUpdated
        )
    }
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

private extension AgentUsageStore {
    static func visibleSources(supportedSources: [AgentSource], enabledSources: Set<AgentSource>) -> [AgentSource] {
        let filteredRealSources = supportedSources
            .filter { $0 != .all }
            .filter { enabledSources.contains($0) }

        if filteredRealSources.count >= 2 {
            return [.all] + filteredRealSources
        }

        return filteredRealSources
    }
}
