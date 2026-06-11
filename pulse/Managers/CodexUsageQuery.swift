import Foundation
import SQLite3

enum CodexUsageQuery {

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
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        let codexDir = homeDirectoryURL.appendingPathComponent(".codex")
        let statePattern = "state_*.sqlite"

        guard let contents = try? fileManager.contentsOfDirectory(at: codexDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }

        let stateDBs = contents.filter { url in
            url.lastPathComponent.matchingStateDB(pattern: statePattern)
        }.filter { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { return false }
            return size > 0
        }

        guard stateDBs.isEmpty == false else {
            return nil
        }

        return stateDBs.max { lhs, rhs in
            let lhsVersion = lhs.lastPathComponent.stateDBVersion
            let rhsVersion = rhs.lastPathComponent.stateDBVersion
            if lhsVersion != rhsVersion { return lhsVersion < rhsVersion }
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    static func loadSnapshot(databaseURL: URL) throws -> CodexUsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw QueryError.databaseNotFound(path: databaseURL.path)
        }

        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?

        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw QueryError.databaseOpenFailed(message: message)
        }

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
            where archived = 0 or archived is null
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

    static func loadSubagentEdges(databaseURL: URL, threadID: String) throws -> [CodexSubagentEdge] {
        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?

        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw QueryError.databaseOpenFailed(message: message)
        }

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
        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?

        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw QueryError.databaseOpenFailed(message: message)
        }

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

private extension String {
    var stateDBVersion: Int {
        let pattern = /^state_(\d+)\.sqlite$/
        guard let match = try? pattern.firstMatch(in: self) else { return -1 }
        return Int(match.1) ?? -1
    }

    func matchingStateDB(pattern: String) -> Bool {
        let pattern = /^state_\d+\.sqlite$/
        return (try? pattern.firstMatch(in: self)) != nil
    }
}
