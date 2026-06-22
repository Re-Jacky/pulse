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
    let availableSources: [AgentSource]

    private var hasLoadedGeneralData = false
    private var derivedDataCache: (key: DerivedDataCacheKey, value: AgentUsageDerivedViewData)?

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
            let detail = try repository.loadCodexDetail(threadID: threadID)
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
        derivedDataCache = nil
    }
    #endif

    // MARK: - Derivation

    func derivedData(for inputSelection: AgentUsageSelection) -> AgentUsageDerivedViewData {
        let selection = reconcile(inputSelection)
        let cacheKey = DerivedDataCacheKey(selection: selection, refreshGeneration: state.refreshGeneration)
        if let derivedDataCache, derivedDataCache.key == cacheKey {
            return derivedDataCache.value
        }

        let openCodeSnapshot: OpenCodeUsageSnapshot
        if selection.timeRange == .allTime {
            openCodeSnapshot = state.openCodeCumulativeSnapshot.filtered(to: selection.timeRange)
        } else {
            openCodeSnapshot = aggregatedSnapshot(for: selection.timeRange)
        }
        let codexSnapshot: CodexUsageSnapshot
        if selection.timeRange == .allTime {
            codexSnapshot = state.codexSnapshot.filtered(to: selection.timeRange)
        } else if state.codexDailyBuckets.isEmpty {
            codexSnapshot = state.codexSnapshot.filtered(to: selection.timeRange)
        } else {
            codexSnapshot = aggregatedCodexSnapshot(for: selection.timeRange)
        }
        let scope = selection.scope

        let summary: AgentUsageSummary = {
            let baseSummary: AgentUsageSummary = switch selection.source {
            case .all:
                AgentUsageSummary.merge(
                    openCodeSnapshot.summary(for: scope),
                    codexSnapshot.summary(for: scope)
                )
            case .openCode:
                openCodeSnapshot.summary(for: scope)
            case .codex:
                codexSnapshot.summary(for: scope)
            }

            return replacingLastUpdated(
                in: baseSummary,
                with: latestActivityDate(
                    for: selection.source,
                    scope: scope,
                    range: selection.timeRange,
                    openCodeSnapshot: openCodeSnapshot,
                    codexSnapshot: codexSnapshot
                )
            )
        }()

        let derivedData = AgentUsageDerivedViewData(
            selection: selection,
            scope: scope,
            summary: summary,
            projectOptions: buildProjectOptions(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            sessionOptions: buildSessionOptions(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            tokenFlowData: buildTokenFlowData(selection: selection, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            usageMetrics: buildUsageMetrics(summary: summary),
            summaryPills: buildSummaryPills(summary: summary),
            contextRows: buildContextRows(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            providerBreakdown: buildProviderBreakdown(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            modelBreakdownRows: buildModelBreakdownRows(selection: selection, scope: scope, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
            selectedOpenCodeSession: selection.source == .openCode ? normalizedOpenCodeSession(id: selection.sessionID, range: selection.timeRange, snapshot: openCodeSnapshot) : nil,
            selectedCodexSession: selection.source == .codex ? normalizedCodexSession(id: selection.sessionID, range: selection.timeRange, snapshot: codexSnapshot) : nil,
            codexDetailThreadID: selection.source == .codex && selection.isSessionScope ? selection.sessionID : nil,
            isSessionScope: selection.isSessionScope,
            showsByModel: selection.source != .all && selection.isSessionScope == false,
            showsTokenFlow: selection.source == .all && selection.timeRange != .today
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
            previousState: state
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

        do {
            openCodeSnapshot = try repository.loadOpenCodeCumulativeSnapshot()
            dailyBuckets = try repository.loadOpenCodeDailyBuckets()
            loadedAnySource = true
        } catch let error as OpenCodeUsageQuery.QueryError {
            firstError = .openCode(error)
        } catch {
            firstError = .openCode(.queryStepFailed(message: error.localizedDescription))
        }

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

        lastError = result.lastError
        if result.loadedAnySource {
            hasLoadedGeneralData = true
        }

        isLoading = false
        isRefreshing = false
    }

    private func aggregatedSnapshot(for range: AgentTimeRange) -> OpenCodeUsageSnapshot {
        let dayRange = agentUsageDayRange(for: range)
        let meta = state.openCodeCumulativeSnapshot

        let grouped = Dictionary(grouping: state.openCodeDailyBuckets) { $0.sessionID }

        let records: [OpenCodeSessionRecord] = grouped.compactMap { sessionID, buckets in
            let inRange = buckets.filter { $0.day >= dayRange.lowerBound && $0.day < dayRange.upperBound }
            guard inRange.isEmpty == false,
                  let m = meta.sessions.first(where: { $0.id == sessionID })
            else { return nil }

            let updatedAt = inRange.compactMap {
                $0.latestActivityAt ?? approximateOpenCodeActivityDate(for: $0.day, relativeTo: m.updatedAt)
            }.max() ?? m.updatedAt

            return OpenCodeSessionRecord(
                id: m.id,
                title: m.title,
                directory: m.directory,
                agent: m.agent,
                modelProviderID: m.modelProviderID,
                modelID: m.modelID,
                modelVariant: m.modelVariant,
                inputTokens: inRange.reduce(0) { $0 + $1.inputTokens },
                outputTokens: inRange.reduce(0) { $0 + $1.outputTokens },
                reasoningTokens: inRange.reduce(0) { $0 + $1.reasoningTokens },
                cacheReadTokens: inRange.reduce(0) { $0 + $1.cacheReadTokens },
                cacheWriteTokens: inRange.reduce(0) { $0 + $1.cacheWriteTokens },
                cost: inRange.reduce(0.0) { $0 + $1.cost },
                createdAt: m.createdAt,
                updatedAt: updatedAt
            )
        }

        return OpenCodeUsageSnapshot(sessions: records)
    }

    private func aggregatedCodexSnapshot(for range: AgentTimeRange) -> CodexUsageSnapshot {
        let dayRange = agentUsageDayRange(for: range)
        let meta = state.codexSnapshot
        let grouped = Dictionary(grouping: state.codexDailyBuckets) { $0.sessionID }

        let records: [CodexSessionRecord] = grouped.compactMap { sessionID, buckets in
            let inRange = buckets.filter { $0.day >= dayRange.lowerBound && $0.day < dayRange.upperBound }
            guard inRange.isEmpty == false,
                  let session = meta.sessions.first(where: { $0.id == sessionID })
            else { return nil }

            let updatedAt = inRange.compactMap {
                $0.latestActivityAt ?? approximateCodexActivityDate(for: $0.day, relativeTo: session.updatedAt)
            }.max() ?? session.updatedAt

            return CodexSessionRecord(
                id: session.id,
                title: session.title,
                cwd: session.cwd,
                model: session.model,
                modelProvider: session.modelProvider,
                tokensUsed: inRange.reduce(0) { $0 + $1.totalTokens },
                inputTokens: inRange.reduce(0) { $0 + $1.inputTokens },
                outputTokens: inRange.reduce(0) { $0 + $1.outputTokens },
                reasoningTokens: inRange.reduce(0) { $0 + $1.reasoningTokens },
                cacheReadTokens: inRange.reduce(0) { $0 + $1.cacheReadTokens },
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

    private func dayRange(for range: AgentTimeRange) -> Range<Int> {
        agentUsageDayRange(for: range)
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
            return allDirs.map { dir -> SearchableSelectorOption in
                let ocSessions = ocProjects[dir] ?? []
                let cxSessions = cxProjects[dir] ?? []
                let totalTokens = ocSessions.reduce(0) { $0 + $1.totalTokens } + cxSessions.reduce(0) { $0 + $1.tokensUsed }
                let sessionsCount = ocSessions.count + cxSessions.count
                return SearchableSelectorOption(
                    id: dir,
                    title: URL(fileURLWithPath: dir).lastPathComponent,
                    subtitle: "\(compact(totalTokens)) total tokens \u{2022} \(sessionsCount) sessions \u{2022} \(dir)"
                )
            }
            .sorted { lhs, rhs in
                let lhsTokens = totalTokensForProject(dir: lhs.id, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot)
                let rhsTokens = totalTokensForProject(dir: rhs.id, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot)
                if lhsTokens == rhsTokens {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhsTokens > rhsTokens
            }
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

    private func totalTokensForProject(dir: String, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> Int {
        let ocTokens = openCodeSnapshot.sessions.filter { $0.directory == dir }.reduce(0) { $0 + $1.totalTokens }
        let cxTokens = codexSnapshot.sessions.filter { $0.cwd == dir && $0.isSubagent == false }.reduce(0) { $0 + $1.tokensUsed }
        return ocTokens + cxTokens
    }

    private func buildSessionOptions(selection: AgentUsageSelection, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [SearchableSelectorOption] {
        switch selection.source {
        case .all:
            return []
        case .openCode:
            guard let projectDirectory = selection.projectDirectory else { return [] }
            let latestBySession = openCodeLatestActivityBySession(
                range: selection.timeRange,
                snapshot: openCodeSnapshot
            )
            return openCodeSnapshot.sessionOptions(for: projectDirectory).map {
                let updatedAt = latestBySession[$0.id] ?? $0.updatedAt
                return SearchableSelectorOption(
                    id: $0.id,
                    title: $0.title,
                    subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime(updatedAt)) \u{2022} \($0.modelDisplayName)"
                )
            }
        case .codex:
            guard let projectDirectory = selection.projectDirectory else { return [] }
            let latestBySession = codexLatestActivityBySession(
                range: selection.timeRange,
                snapshot: codexSnapshot
            )
            return codexSnapshot.sessionOptions(for: projectDirectory).map {
                let updatedAt = latestBySession[$0.id] ?? $0.updatedAt
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
        guard selection.source == .all, selection.timeRange != .today else { return [] }

        let openCodeTotals = openCodeTokenFlowTotals(
            range: selection.timeRange,
            snapshot: openCodeSnapshot
        )
        let codexTotals = codexTokenFlowTotals(
            range: selection.timeRange,
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
        switch selection.timeRange {
        case .allTime: bucketSize = max(1, Int(ceil(Double(totalDays) / 30)))
        default: bucketSize = 1
        }

        var buckets: [TokenUsageDataPoint] = []
        var cursor = earliestDay
        while cursor <= latestDay {
            let bucketEnd = cursor + bucketSize
            let sum = totalsByDay.reduce(0) { partial, entry in
                let (day, value) = entry
                guard day >= cursor && day < bucketEnd else { return partial }
                return partial + value
            }
            let date = Date(timeIntervalSince1970: Double(cursor * 86_400_000) / 1000)
            buckets.append(TokenUsageDataPoint(date: date, totalTokens: sum, bucketSizeDays: bucketSize))
            cursor = bucketEnd
        }
        return buckets
    }

    private func openCodeTokenFlowTotals(
        range: AgentTimeRange,
        snapshot: OpenCodeUsageSnapshot
    ) -> [Int: Int] {
        if state.openCodeDailyBuckets.isEmpty == false {
            let dayRange = dayRange(for: range)
            return state.openCodeDailyBuckets.reduce(into: [:]) { totals, bucket in
                guard bucket.day >= dayRange.lowerBound && bucket.day < dayRange.upperBound else { return }
                let value = bucket.inputTokens + bucket.outputTokens + bucket.reasoningTokens + bucket.cacheReadTokens + bucket.cacheWriteTokens
                totals[bucket.day, default: 0] += value
            }
        }

        return snapshot.sessions.reduce(into: [:]) { totals, session in
            let day = agentUsageDayIdentifier(for: session.updatedAt)
            totals[day, default: 0] += session.totalTokens
        }
    }

    private func codexTokenFlowTotals(
        range: AgentTimeRange,
        snapshot: CodexUsageSnapshot
    ) -> [Int: Int] {
        if state.codexDailyBuckets.isEmpty == false {
            let dayRange = dayRange(for: range)
            return state.codexDailyBuckets.reduce(into: [:]) { totals, bucket in
                guard bucket.day >= dayRange.lowerBound && bucket.day < dayRange.upperBound else { return }
                totals[bucket.day, default: 0] += bucket.totalTokens
            }
        }

        return snapshot.sessions.reduce(into: [:]) { totals, session in
            let day = agentUsageDayIdentifier(for: session.updatedAt)
            totals[day, default: 0] += session.tokensUsed
        }
    }

    private func legacyTokenFlowData(openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot, range: AgentTimeRange) -> [TokenUsageDataPoint] {
        let now = Date()
        let calendar = Calendar.current

        let minOC = openCodeSnapshot.sessions.min(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
        let minCX = codexSnapshot.sessions.min(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
        guard let earliest = [minOC, minCX].compactMap({ $0 }).min() else { return [] }

        let earliestDay = calendar.startOfDay(for: earliest)
        let nowDay = calendar.startOfDay(for: now)
        let totalDays = calendar.dateComponents([.day], from: earliestDay, to: nowDay).day.flatMap({ $0 > 0 ? $0 : 1 }) ?? 1
        let bucketSize: Int
        switch range {
        case .allTime: bucketSize = max(1, Int(ceil(Double(totalDays) / 30)))
        default: bucketSize = 1
        }

        var entries: [(date: Date, tokens: Int)] = []
        for session in openCodeSnapshot.sessions {
            entries.append((calendar.startOfDay(for: session.updatedAt), session.totalTokens))
        }
        for session in codexSnapshot.sessions {
            entries.append((calendar.startOfDay(for: session.updatedAt), session.tokensUsed))
        }

        var buckets: [TokenUsageDataPoint] = []
        var cursor = earliestDay
        while cursor <= nowDay {
            guard let bucketEnd = calendar.date(byAdding: .day, value: bucketSize, to: cursor) else { break }
            let sum = entries
                .filter { $0.date >= cursor && $0.date < bucketEnd }
                .reduce(0) { $0 + $1.tokens }
            buckets.append(TokenUsageDataPoint(date: cursor, totalTokens: sum, bucketSizeDays: bucketSize))
            cursor = bucketEnd
        }
        return buckets
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
        pills.append(AgentUsageSummaryPill(id: "sessions", title: "Sessions", valueText: "\(summary.sessionsCount)"))
        pills.append(AgentUsageSummaryPill(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-"))
        if let cost = summary.cost, cost > 0 {
            pills.append(AgentUsageSummaryPill(id: "cost", title: "Cost", valueText: String(format: "$%.2f", cost)))
        }
        return pills
    }

    private func buildContextRows(selection: AgentUsageSelection, scope: AgentScope, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [AgentUsageDetailRow] {
        guard selection.source != .all else { return [] }

        var rows: [AgentUsageDetailRow] = []

        switch selection.source {
        case .all:
            break
        case .openCode:
            let latestBySession = openCodeLatestActivityBySession(range: selection.timeRange, snapshot: openCodeSnapshot)
            let summary = replacingLastUpdated(
                in: openCodeSnapshot.summary(for: scope),
                with: latestActivityDate(
                    for: .openCode,
                    scope: scope,
                    range: selection.timeRange,
                    openCodeSnapshot: openCodeSnapshot,
                    codexSnapshot: codexSnapshot
                )
            )
            switch scope {
            case .allProjects:
                rows.append(AgentUsageDetailRow(id: "projectsCount", title: "Projects Count", valueText: "\(openCodeSnapshot.projectOptions.count)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .project(let directory):
                rows.append(AgentUsageDetailRow(id: "projectName", title: "Project Name", valueText: URL(fileURLWithPath: directory).lastPathComponent, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: directory, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .session:
                let session = openCodeSnapshot.sessions.first(where: { $0.id == selection.sessionID })
                let updatedAt = selection.sessionID.flatMap { latestBySession[$0] } ?? session?.updatedAt
                rows.append(AgentUsageDetailRow(id: "title", title: "Title", valueText: session?.title ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: session?.directory ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "agent", title: "Agent", valueText: session?.agent ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "providerModel", title: "Provider / Model", valueText: session.map { OpenCodeUsageSnapshot.modelDisplayName(providerID: $0.modelProviderID, modelID: $0.modelID, variant: $0.modelVariant) } ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "created", title: "Created", valueText: session.map { shortDateTime($0.createdAt) } ?? "-", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: updatedAt.map(shortDateTime) ?? "-", secondaryText: nil))
            }
        case .codex:
            let latestBySession = codexLatestActivityBySession(range: selection.timeRange, snapshot: codexSnapshot)
            let summary = replacingLastUpdated(
                in: codexSnapshot.summary(for: scope),
                with: latestActivityDate(
                    for: .codex,
                    scope: scope,
                    range: selection.timeRange,
                    openCodeSnapshot: openCodeSnapshot,
                    codexSnapshot: codexSnapshot
                )
            )
            switch scope {
            case .allProjects:
                rows.append(AgentUsageDetailRow(id: "projectsCount", title: "Projects Count", valueText: "\(codexSnapshot.projectOptions.count)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .project(let directory):
                rows.append(AgentUsageDetailRow(id: "projectName", title: "Project Name", valueText: URL(fileURLWithPath: directory).lastPathComponent, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "fullPath", title: "Full Path", valueText: directory, secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "sessionsCount", title: "Sessions Count", valueText: "\(summary.sessionsCount)", secondaryText: nil))
                rows.append(AgentUsageDetailRow(id: "lastUpdated", title: "Last Updated", valueText: summary.lastUpdated.map(shortDateTime) ?? "-", secondaryText: nil))
            case .session:
                let session = codexSnapshot.sessions.first(where: { $0.id == selection.sessionID })
                let updatedAt = selection.sessionID.flatMap { latestBySession[$0] } ?? session?.updatedAt
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

    private func replacingLastUpdated(in summary: AgentUsageSummary, with lastUpdated: Date?) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: summary.totalTokens,
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            reasoningTokens: summary.reasoningTokens,
            cacheReadTokens: summary.cacheReadTokens,
            cacheWriteTokens: summary.cacheWriteTokens,
            sessionsCount: summary.sessionsCount,
            cost: summary.cost,
            lastUpdated: lastUpdated ?? summary.lastUpdated
        )
    }

    private func latestActivityDate(
        for source: AgentSource,
        scope: AgentScope,
        range: AgentTimeRange,
        openCodeSnapshot: OpenCodeUsageSnapshot,
        codexSnapshot: CodexUsageSnapshot
    ) -> Date? {
        switch source {
        case .all:
            return [
                latestActivityDate(for: .openCode, scope: scope, range: range, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot),
                latestActivityDate(for: .codex, scope: scope, range: range, openCodeSnapshot: openCodeSnapshot, codexSnapshot: codexSnapshot)
            ].compactMap { $0 }.max()
        case .openCode:
            let latestBySession = openCodeLatestActivityBySession(range: range, snapshot: openCodeSnapshot)
            let filtered = latestBySession.filter { openCodeSessionIDs(in: scope, snapshot: openCodeSnapshot).contains($0.key) }
            return filtered.values.max() ?? openCodeSnapshot.summary(for: scope).lastUpdated
        case .codex:
            let latestBySession = codexLatestActivityBySession(range: range, snapshot: codexSnapshot)
            let filtered = latestBySession.filter { codexSessionIDs(in: scope, snapshot: codexSnapshot).contains($0.key) }
            return filtered.values.max() ?? codexSnapshot.summary(for: scope).lastUpdated
        }
    }

    private func openCodeLatestActivityBySession(
        range: AgentTimeRange,
        snapshot: OpenCodeUsageSnapshot
    ) -> [String: Date] {
        let dayRange = dayRange(for: range)
        let metadataBySession = Dictionary(uniqueKeysWithValues: state.openCodeCumulativeSnapshot.sessions.map { ($0.id, $0) })

        return state.openCodeDailyBuckets.reduce(into: [:]) { latestBySession, bucket in
            guard dayRange.contains(bucket.day) else { return }
            guard let metadata = metadataBySession[bucket.sessionID] else { return }
            let activityAt = bucket.latestActivityAt ?? approximateOpenCodeActivityDate(for: bucket.day, relativeTo: metadata.updatedAt)
            latestBySession[bucket.sessionID] = max(latestBySession[bucket.sessionID] ?? .distantPast, activityAt)
        }
    }

    private func codexLatestActivityBySession(
        range: AgentTimeRange,
        snapshot: CodexUsageSnapshot
    ) -> [String: Date] {
        let dayRange = dayRange(for: range)
        let metadataBySession = Dictionary(uniqueKeysWithValues: state.codexSnapshot.sessions.map { ($0.id, $0) })

        return state.codexDailyBuckets.reduce(into: [:]) { latestBySession, bucket in
            guard dayRange.contains(bucket.day) else { return }
            guard let metadata = metadataBySession[bucket.sessionID] else { return }
            let activityAt = bucket.latestActivityAt ?? approximateCodexActivityDate(for: bucket.day, relativeTo: metadata.updatedAt)
            latestBySession[bucket.sessionID] = max(latestBySession[bucket.sessionID] ?? .distantPast, activityAt)
        }
    }

    private func openCodeSessionIDs(in scope: AgentScope, snapshot: OpenCodeUsageSnapshot) -> Set<String> {
        switch scope {
        case .allProjects:
            return Set(snapshot.sessions.map(\.id))
        case .project(let directory):
            return Set(snapshot.sessions.filter { $0.directory == directory }.map(\.id))
        case .session(_, let sessionID):
            return [sessionID]
        }
    }

    private func codexSessionIDs(in scope: AgentScope, snapshot: CodexUsageSnapshot) -> Set<String> {
        switch scope {
        case .allProjects:
            return Set(snapshot.sessions.filter { $0.isSubagent == false }.map(\.id))
        case .project(let directory):
            return Set(snapshot.sessions.filter { $0.cwd == directory && $0.isSubagent == false }.map(\.id))
        case .session(_, let sessionID):
            return [sessionID]
        }
    }

    private func normalizedOpenCodeSession(
        id: String?,
        range: AgentTimeRange,
        snapshot: OpenCodeUsageSnapshot
    ) -> OpenCodeSessionRecord? {
        guard let id, let session = snapshot.sessions.first(where: { $0.id == id }) else { return nil }
        let latestBySession = openCodeLatestActivityBySession(range: range, snapshot: snapshot)
        guard let updatedAt = latestBySession[id] else { return session }

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
            cost: session.cost,
            createdAt: session.createdAt,
            updatedAt: updatedAt
        )
    }

    private func normalizedCodexSession(
        id: String?,
        range: AgentTimeRange,
        snapshot: CodexUsageSnapshot
    ) -> CodexSessionRecord? {
        guard let id, let session = snapshot.sessions.first(where: { $0.id == id }) else { return nil }
        let latestBySession = codexLatestActivityBySession(range: range, snapshot: snapshot)
        guard let updatedAt = latestBySession[id] else { return session }

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
        case .openCode: return openCodeSnapshot.providerBreakdown(for: scope)
        case .codex: return codexSnapshot.providerBreakdown(for: scope)
        }
    }

    private func buildModelBreakdownRows(selection: AgentUsageSelection, scope: AgentScope, openCodeSnapshot: OpenCodeUsageSnapshot, codexSnapshot: CodexUsageSnapshot) -> [AgentUsageDetailRow] {
        guard selection.source != .all else { return [] }
        switch selection.source {
        case .all: return []
        case .openCode:
            return openCodeSnapshot.modelBreakdown(for: scope).map {
                AgentUsageDetailRow(
                    id: "\($0.providerID)/\($0.modelID)",
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
