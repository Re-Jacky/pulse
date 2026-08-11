import Foundation

protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }
    var claudeCodeProjectsURL: URL { get }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket]
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket]
    func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot
    func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket]
    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail
}

struct AgentUsageRepository: AgentUsageRepositorying {
    let openCodeDatabaseURL: URL
    let codexDatabaseURL: URL?
    let claudeCodeProjectsURL: URL

    init(
        openCodeDatabaseURL: URL = OpenCodeUsageQuery.resolveDatabaseURL(),
        codexDatabaseURL: URL? = CodexUsageQuery.resolveDatabaseURL(),
        claudeCodeProjectsURL: URL = ClaudeCodeUsageQuery.resolveProjectsDirectory()
    ) {
        self.openCodeDatabaseURL = openCodeDatabaseURL
        self.codexDatabaseURL = codexDatabaseURL
        self.claudeCodeProjectsURL = claudeCodeProjectsURL
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

    func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot {
        try ClaudeCodeUsageQuery.loadSnapshot(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
    }

    func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket] {
        try ClaudeCodeUsageQuery.loadDailyBuckets(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
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
