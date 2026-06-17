import Foundation

protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket]
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket]
    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail
}

struct AgentUsageRepository: AgentUsageRepositorying {
    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?

    init(
        openCodeDatabaseURL: URL = OpenCodeUsageQuery.resolveDatabaseURL(),
        codexDatabaseURL: URL? = CodexUsageQuery.resolveDatabaseURL()
    ) {
        self.openCodeDatabaseURL = openCodeDatabaseURL
        self.codexDatabaseURL = codexDatabaseURL
    }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot {
        try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
    }

    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] {
        try OpenCodeUsageQuery.loadDailyBuckets(databaseURL: openCodeDatabaseURL)
    }

    func loadCodexSnapshot() throws -> CodexUsageSnapshot {
        guard let codexDatabaseURL else {
            throw CodexUsageQuery.QueryError.databaseNotFound(path: "Codex database not found")
        }
        return try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
    }

    func loadCodexDailyBuckets() throws -> [CodexDailyBucket] {
        try CodexUsageQuery.loadDailyBuckets()
    }

    func loadCodexDetail(threadID: String) throws -> CodexSessionDetail {
        guard let codexDatabaseURL else {
            throw CodexUsageQuery.QueryError.databaseNotFound(path: "Codex database not found")
        }

        let edges = try CodexUsageQuery.loadSubagentEdges(databaseURL: codexDatabaseURL, threadID: threadID)
        let goals = try CodexUsageQuery.loadGoals(databaseURL: codexDatabaseURL, threadID: threadID)

        return CodexSessionDetail(
            threadID: threadID,
            edges: edges,
            goals: goals
        )
    }
}
