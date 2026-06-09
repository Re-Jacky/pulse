import Foundation
import Combine
import SQLite3

final class OpenCodeUsageStore: ObservableObject {
    enum LoadError: Error, Equatable, LocalizedError {
        case databaseNotFound(path: String)
        case databaseOpenFailed(message: String)
        case queryPrepareFailed(message: String)
        case queryStepFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let path):
                return "OpenCode database not found at \(path)"
            case .databaseOpenFailed(let message):
                return "Failed to open OpenCode database: \(message)"
            case .queryPrepareFailed(let message):
                return "Failed to prepare OpenCode query: \(message)"
            case .queryStepFailed(let message):
                return "Failed to read OpenCode rows: \(message)"
            }
        }
    }

    @Published private(set) var snapshot = OpenCodeUsageSnapshot(sessions: [])
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: LoadError?
    @Published private(set) var hasLoaded = false

    let databaseURL: URL

    init(databaseURL: URL = OpenCodeUsageStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
    }

    func refresh() {
        let firstLoad = hasLoaded == false
        if firstLoad {
            isLoading = true
        } else {
            isRefreshing = true
        }

        do {
            snapshot = try Self.loadSnapshot(databaseURL: databaseURL)
            lastError = nil
        } catch let error as LoadError {
            lastError = error
        } catch {
            lastError = .queryStepFailed(message: error.localizedDescription)
        }

        hasLoaded = true
        isLoading = false
        isRefreshing = false
    }

    func refreshIfNeeded() {
        guard hasLoaded == false else { return }
        refresh()
    }

    static func loadSnapshot(databaseURL: URL) throws -> OpenCodeUsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw LoadError.databaseNotFound(path: databaseURL.path)
        }

        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw LoadError.databaseOpenFailed(message: message)
        }
        defer { sqlite3_close(db) }

        let sql = """
        select
            id,
            title,
            directory,
            coalesce(agent, ''),
            coalesce(json_extract(model, '$.providerID'), ''),
            coalesce(json_extract(model, '$.id'), ''),
            nullif(json_extract(model, '$.variant'), ''),
            coalesce(tokens_input, 0),
            coalesce(tokens_output, 0),
            coalesce(tokens_reasoning, 0),
            coalesce(tokens_cache_read, 0),
            coalesce(tokens_cache_write, 0),
            coalesce(cost, 0),
            time_created,
            time_updated
        from session
        order by time_updated desc
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoadError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [OpenCodeSessionRecord] = []

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }

            guard stepResult == SQLITE_ROW else {
                throw LoadError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 13)) / 1000)
            let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 14)) / 1000)

            sessions.append(
                OpenCodeSessionRecord(
                    id: stringColumn(statement, index: 0),
                    title: stringColumn(statement, index: 1),
                    directory: stringColumn(statement, index: 2),
                    agent: stringColumn(statement, index: 3),
                    modelProviderID: stringColumn(statement, index: 4),
                    modelID: stringColumn(statement, index: 5),
                    modelVariant: optionalStringColumn(statement, index: 6),
                    inputTokens: Int(sqlite3_column_int64(statement, 7)),
                    outputTokens: Int(sqlite3_column_int64(statement, 8)),
                    reasoningTokens: Int(sqlite3_column_int64(statement, 9)),
                    cacheReadTokens: Int(sqlite3_column_int64(statement, 10)),
                    cacheWriteTokens: Int(sqlite3_column_int64(statement, 11)),
                    cost: sqlite3_column_double(statement, 12),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return OpenCodeUsageSnapshot(sessions: sessions)
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
