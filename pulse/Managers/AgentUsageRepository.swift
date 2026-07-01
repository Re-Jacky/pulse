import Foundation

protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket]
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket]
    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail
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
        try CodexUsageQuery.loadMergedSnapshot(includeTranscriptURLs: false)
    }

    func loadCodexDailyBuckets() throws -> [CodexDailyBucket] {
        try CodexUsageQuery.loadDailyBuckets()
    }

    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> CodexSessionDetail {
        try CodexUsageQuery.loadDetail(
            threadID: threadID,
            preferredDatabaseURL: codexDatabaseURL,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
    }
}
