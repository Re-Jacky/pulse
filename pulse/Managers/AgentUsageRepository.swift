import Foundation

protocol AgentUsageRepositorying {
    var openCodeDatabaseURL: URL { get }
    var codexDatabaseURL: URL? { get }
    var claudeCodeProjectsURL: URL { get }

    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket]
    /// Loads the cumulative snapshot and daily buckets together. The default
    /// implementation calls the two methods above; the concrete repository
    /// overrides it to scan the OpenCode database only once.
    func loadOpenCodeUsage() throws -> OpenCodeUsageLoadResult
    func loadCodexSnapshot() throws -> CodexUsageSnapshot
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket]
    func loadClaudeCodeSnapshot() throws -> ClaudeCodeUsageSnapshot
    func loadClaudeCodeDailyBuckets() throws -> [ClaudeCodeDailyBucket]
    /// Loads the Claude Code snapshot and daily buckets together. The default
    /// implementation calls the two methods above; the concrete repository
    /// overrides it to visit the transcript cache only once.
    func loadClaudeCodeUsage() throws -> ClaudeCodeUsageLoadResult
    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail
}

extension AgentUsageRepositorying {
    func loadOpenCodeUsage() throws -> OpenCodeUsageLoadResult {
        OpenCodeUsageLoadResult(
            snapshot: try loadOpenCodeCumulativeSnapshot(),
            dailyBuckets: try loadOpenCodeDailyBuckets()
        )
    }

    func loadClaudeCodeUsage() throws -> ClaudeCodeUsageLoadResult {
        ClaudeCodeUsageLoadResult(
            snapshot: try loadClaudeCodeSnapshot(),
            dailyBuckets: try loadClaudeCodeDailyBuckets()
        )
    }
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

    func loadOpenCodeUsage() throws -> OpenCodeUsageLoadResult {
        try OpenCodeUsageQuery.loadUsage(databaseURL: openCodeDatabaseURL)
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

    func loadClaudeCodeUsage() throws -> ClaudeCodeUsageLoadResult {
        try ClaudeCodeUsageQuery.loadUsage(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
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
