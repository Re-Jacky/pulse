import Foundation
import SQLite3

enum CodexUsageQuery {

    fileprivate struct CumulativeUsage {
        let inputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
    }

    enum QueryError: Error, Equatable, LocalizedError {
        case databaseNotFound(path: String)
        case databaseOpenFailed(message: String)
        case queryPrepareFailed(message: String)
        case queryStepFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let path):
                return "Codex database not found at \(path)"
            case .databaseOpenFailed(let message):
                return "Failed to open Codex database: \(message)"
            case .queryPrepareFailed(let message):
                return "Failed to prepare Codex query: \(message)"
            case .queryStepFailed(let message):
                return "Failed to read Codex rows: \(message)"
            }
        }
    }

    static func resolveDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        if let explicitPath = environment["CODEX_DB_PATH"], explicitPath.isEmpty == false {
            let url = URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path), databaseContainsThreadsTable(databaseURL: url) {
                return url
            }
        }

        let stateDBs = validStateDatabaseURLs(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )

        guard stateDBs.isEmpty == false else {
            return nil
        }

        return stateDBs.max { lhs, rhs in
            let lhsDate = stateDatabaseActivityDate(for: lhs)
            let rhsDate = stateDatabaseActivityDate(for: rhs)
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let lhsVersion = lhs.lastPathComponent.stateDBVersion
            let rhsVersion = rhs.lastPathComponent.stateDBVersion
            if lhsVersion != rhsVersion { return lhsVersion < rhsVersion }
            return lhs.path < rhs.path
        }
    }

    static func loadMergedSnapshot(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot {
        let databaseURLs = validStateDatabaseURLs(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )

        guard databaseURLs.isEmpty == false else {
            throw QueryError.databaseNotFound(path: homeDirectoryURL.appendingPathComponent(".codex").path)
        }

        var sessionsByID: [String: CodexSessionRecord] = [:]

        for databaseURL in databaseURLs {
            let snapshot = try loadSnapshot(databaseURL: databaseURL)
            for session in snapshot.sessions {
                if let existing = sessionsByID[session.id], existing.updatedAt >= session.updatedAt {
                    continue
                }
                sessionsByID[session.id] = session
            }
        }

        return CodexUsageSnapshot(
            sessions: sessionsByID.values.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        )
    }

    static func loadSnapshot(databaseURL: URL) throws -> CodexUsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw QueryError.databaseNotFound(path: databaseURL.path)
        }

        let db = try openReadOnlyDatabase(databaseURL: databaseURL)
        defer { sqlite3_close(db) }

        let sql = """
            select
                id,
                coalesce(title, ''),
                coalesce(cwd, ''),
                coalesce(model, ''),
                coalesce(model_provider, ''),
                coalesce(tokens_used, 0),
                coalesce(reasoning_effort, ''),
                coalesce(thread_source, ''),
                nullif(agent_nickname, ''),
                nullif(agent_role, ''),
                coalesce(created_at_ms, 0),
                coalesce(updated_at_ms, 0)
            from threads
            order by updated_at_ms desc
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [CodexSessionRecord] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 10)) / 1000)
            let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 11)) / 1000)

            sessions.append(
                CodexSessionRecord(
                    id: stringColumn(statement, index: 0),
                    title: stringColumn(statement, index: 1),
                    cwd: stringColumn(statement, index: 2),
                    model: stringColumn(statement, index: 3),
                    modelProvider: stringColumn(statement, index: 4),
                    tokensUsed: Int(sqlite3_column_int64(statement, 5)),
                    inputTokens: nil,
                    outputTokens: nil,
                    reasoningTokens: nil,
                    cacheReadTokens: nil,
                    reasoningEffort: stringColumn(statement, index: 6),
                    threadSource: stringColumn(statement, index: 7),
                    agentNickname: optionalStringColumn(statement, index: 8),
                    agentRole: optionalStringColumn(statement, index: 9),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return CodexUsageSnapshot(sessions: sessions)
    }

    static func loadDailyBuckets(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> [CodexDailyBucket] {
        let transcriptURLs = candidateTranscriptURLs(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )

        var totalsBySessionAndDay: [String: CodexDailyBucket] = [:]

        for url in transcriptURLs {
            try accumulateDailyBuckets(
                transcriptURL: url,
                into: &totalsBySessionAndDay
            )
        }

        return totalsBySessionAndDay
            .compactMap { key, bucket in
                let parts = key.split(separator: "::", maxSplits: 1).map(String.init)
                guard parts.count == 2, let day = Int(parts[1]) else { return nil }
                return CodexDailyBucket(
                    sessionID: parts[0],
                    day: day,
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    reasoningTokens: bucket.reasoningTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    totalTokens: bucket.totalTokens
                )
            }
            .sorted { lhs, rhs in
                if lhs.day == rhs.day {
                    return lhs.sessionID < rhs.sessionID
                }
                return lhs.day < rhs.day
            }
    }

    static func loadSubagentEdges(databaseURL: URL, threadID: String) throws -> [CodexSubagentEdge] {
        let db = try openReadOnlyDatabase(databaseURL: databaseURL)
        defer { sqlite3_close(db) }

        let sql = """
            select parent_thread_id, child_thread_id, coalesce(status, '')
            from thread_spawn_edges
            where parent_thread_id = ? or child_thread_id = ?
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (threadID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (threadID as NSString).utf8String, -1, nil)

        var edges: [CodexSubagentEdge] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            edges.append(
                CodexSubagentEdge(
                    parentThreadID: stringColumn(statement, index: 0),
                    childThreadID: stringColumn(statement, index: 1),
                    status: stringColumn(statement, index: 2)
                )
            )
        }

        return edges
    }

    static func loadGoals(databaseURL: URL, threadID: String) throws -> [CodexGoal] {
        let db = try openReadOnlyDatabase(databaseURL: databaseURL)
        defer { sqlite3_close(db) }

        let sql = """
            select
                coalesce(goal_id, ''),
                coalesce(objective, ''),
                coalesce(status, ''),
                token_budget,
                coalesce(tokens_used, 0)
            from thread_goals
            where thread_id = ?
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (threadID as NSString).utf8String, -1, nil)

        var goals: [CodexGoal] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            let budget: Int? = {
                let val = sqlite3_column_int64(statement, 3)
                return val > 0 ? Int(val) : nil
            }()

            goals.append(
                CodexGoal(
                    id: stringColumn(statement, index: 0),
                    threadID: threadID,
                    objective: stringColumn(statement, index: 1),
                    status: stringColumn(statement, index: 2),
                    tokenBudget: budget,
                    tokensUsed: Int(sqlite3_column_int64(statement, 4))
                )
            )
        }

        return goals
    }
}

private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
}

private func optionalStringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
    let value = stringColumn(statement, index: index)
    return value.isEmpty ? nil : value
}

private func openReadOnlyDatabase(databaseURL: URL) throws -> OpaquePointer? {
    let uri = "file://\(databaseURL.path)?immutable=1"
    var db: OpaquePointer?

    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw CodexUsageQuery.QueryError.databaseOpenFailed(message: message)
    }

    return db
}

private func accumulateDailyBuckets(
    transcriptURL: URL,
    into totalsBySessionAndDay: inout [String: CodexDailyBucket]
) throws {
    guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else {
        throw CodexUsageQuery.QueryError.queryStepFailed(message: "Failed to read transcript at \(transcriptURL.path)")
    }
    defer { try? handle.close() }

    guard let contents = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
        return
    }

    var sessionID: String?
    var previousUsage: CodexUsageQuery.CumulativeUsage?

    for line in contents.split(whereSeparator: \.isNewline) {
        guard let data = line.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any],
              let type = object["type"] as? String else {
            continue
        }

        if type == "session_meta", sessionID == nil,
           let payload = object["payload"] as? [String: Any] {
            sessionID = (payload["session_id"] as? String)
                ?? (payload["sessionId"] as? String)
                ?? (payload["id"] as? String)
            continue
        }

        guard type == "event_msg",
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let timestampString = object["timestamp"] as? String,
              let timestamp = parseCodexTimestamp(timestampString),
              let currentSessionID = sessionID else {
            continue
        }

        guard let currentUsage = parseCumulativeUsage(payload: payload) else {
            continue
        }

        let deltaUsage: CodexUsageQuery.CumulativeUsage
        if hasTotalTokenUsage(payload: payload) {
            let previous = previousUsage ?? CodexUsageQuery.CumulativeUsage(
                inputTokens: 0,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                totalTokens: 0
            )
            deltaUsage = CodexUsageQuery.CumulativeUsage(
                inputTokens: max(0, currentUsage.inputTokens - previous.inputTokens),
                outputTokens: max(0, currentUsage.outputTokens - previous.outputTokens),
                reasoningTokens: max(0, currentUsage.reasoningTokens - previous.reasoningTokens),
                cacheReadTokens: max(0, currentUsage.cacheReadTokens - previous.cacheReadTokens),
                totalTokens: max(0, currentUsage.totalTokens - previous.totalTokens)
            )
            previousUsage = currentUsage
        } else {
            deltaUsage = currentUsage
        }

        guard deltaUsage.totalTokens > 0 else { continue }

        let day = agentUsageDayIdentifier(for: timestamp)
        let key = "\(currentSessionID)::\(day)"
        let deltaBucket = CodexDailyBucket(
            sessionID: currentSessionID,
            day: day,
            inputTokens: deltaUsage.inputTokens,
            outputTokens: deltaUsage.outputTokens,
            reasoningTokens: deltaUsage.reasoningTokens,
            cacheReadTokens: deltaUsage.cacheReadTokens,
            totalTokens: deltaUsage.totalTokens
        )
        let existing = totalsBySessionAndDay[key, default: .zero(sessionID: currentSessionID, day: day)]
        totalsBySessionAndDay[key] = existing.merging(deltaBucket)
    }
}

private func hasTotalTokenUsage(payload: [String: Any]) -> Bool {
    guard let info = payload["info"] as? [String: Any] else { return false }
    return info["total_token_usage"] != nil
}

private func parseCumulativeUsage(payload: [String: Any]) -> CodexUsageQuery.CumulativeUsage? {
    guard let info = payload["info"] as? [String: Any] else { return nil }

    let usageObject = (info["total_token_usage"] as? [String: Any])
        ?? (info["last_token_usage"] as? [String: Any])
    guard let usageObject else { return nil }

    let inputTokens = usageObject["input_tokens"] as? Int ?? 0
    let outputTokens = usageObject["output_tokens"] as? Int ?? 0
    let reasoningTokens = usageObject["reasoning_output_tokens"] as? Int ?? 0
    let cacheReadTokens = usageObject["cached_input_tokens"] as? Int ?? 0
    let totalTokens = (usageObject["total_tokens"] as? Int)
        ?? (inputTokens + outputTokens + reasoningTokens + cacheReadTokens)

    return CodexUsageQuery.CumulativeUsage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        cacheReadTokens: cacheReadTokens,
        totalTokens: totalTokens
    )
}

private func candidateDatabaseURLs(
    homeDirectoryURL: URL,
    fileManager: FileManager
) -> [URL] {
    let codexDir = homeDirectoryURL.appendingPathComponent(".codex")
    let searchDirectories = [
        codexDir,
        codexDir.appendingPathComponent("sqlite")
    ]

    var candidates: [URL] = []
    var seenPaths = Set<String>()

    for directory in searchDirectories {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            continue
        }

        for url in contents where url.lastPathComponent.matchingStateDB(pattern: "state_*.sqlite") {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  size > 0,
                  seenPaths.insert(url.path).inserted else {
                continue
            }

            candidates.append(url)
        }
    }

    return candidates
}

private func validStateDatabaseURLs(
    homeDirectoryURL: URL,
    fileManager: FileManager
) -> [URL] {
    candidateDatabaseURLs(
        homeDirectoryURL: homeDirectoryURL,
        fileManager: fileManager
    )
    .filter(databaseContainsThreadsTable(databaseURL:))
    .sorted { lhs, rhs in
        let lhsDate = stateDatabaseActivityDate(for: lhs)
        let rhsDate = stateDatabaseActivityDate(for: rhs)
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        let lhsVersion = lhs.lastPathComponent.stateDBVersion
        let rhsVersion = rhs.lastPathComponent.stateDBVersion
        if lhsVersion != rhsVersion { return lhsVersion > rhsVersion }
        return lhs.path < rhs.path
    }
}

private func candidateTranscriptURLs(
    homeDirectoryURL: URL,
    fileManager: FileManager
) -> [URL] {
    let codexDirectory = homeDirectoryURL.appendingPathComponent(".codex")
    let sessionsDirectory = codexDirectory.appendingPathComponent("sessions")
    let archivedDirectory = codexDirectory.appendingPathComponent("archived_sessions")

    var urls: [URL] = []
    collectTranscriptURLs(in: sessionsDirectory, fileManager: fileManager, depth: 0, maxDepth: 3, into: &urls)
    collectTranscriptURLs(in: archivedDirectory, fileManager: fileManager, depth: 0, maxDepth: 0, into: &urls)
    return urls
}

private func collectTranscriptURLs(
    in directory: URL,
    fileManager: FileManager,
    depth: Int,
    maxDepth: Int,
    into urls: inout [URL]
) {
    guard let contents = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for url in contents {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            continue
        }

        if isDirectory.boolValue {
            guard depth < maxDepth else { continue }
            collectTranscriptURLs(in: url, fileManager: fileManager, depth: depth + 1, maxDepth: maxDepth, into: &urls)
            continue
        }

        if url.pathExtension == "jsonl" {
            urls.append(url)
        }
    }
}

private func stateDatabaseActivityDate(for url: URL) -> Date {
    let candidates = [
        url,
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-wal"),
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-shm")
    ]

    return candidates.compactMap {
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }.max() ?? .distantPast
}

private func databaseContainsThreadsTable(databaseURL: URL) -> Bool {
    guard let db = try? openReadOnlyDatabase(databaseURL: databaseURL) else {
        return false
    }
    defer { sqlite3_close(db) }

    let sql = """
        select 1
        from sqlite_master
        where type = 'table' and name = 'threads'
        limit 1
        """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        return false
    }
    defer { sqlite3_finalize(statement) }

    return sqlite3_step(statement) == SQLITE_ROW
}

private extension String {
    var stateDBVersion: Int {
        let pattern = /^state_(\d+)\.sqlite$/
        guard let match = try? pattern.firstMatch(in: self) else { return -1 }
        return Int(match.1) ?? -1
    }

    func matchingStateDB(pattern: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^" + pattern.replacingOccurrences(of: "*", with: ".*") + "$")
        let range = NSRange(location: 0, length: utf16.count)
        return regex?.firstMatch(in: self, range: range) != nil
    }
}

private extension ISO8601DateFormatter {
    static let codexUsage: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private func parseCodexTimestamp(_ value: String) -> Date? {
    ISO8601DateFormatter.codexUsage.date(from: value)
        ?? ISO8601DateFormatter().date(from: value)
}
