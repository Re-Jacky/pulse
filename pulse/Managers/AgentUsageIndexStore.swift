import Foundation
import SQLite3

struct AgentUsageIndexRecord: Equatable {
    let metadata: Data
    let payload: Data
}

final class AgentUsageIndexStore {
    enum StoreError: Error {
        case openFailed(code: Int32, message: String)
        case sqlite(code: Int32, message: String)
    }

    static let schemaVersion = 1

    private var database: OpaquePointer!
    private let lock = NSRecursiveLock()

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            database = try Self.openDatabase(at: databaseURL)
            try configureDatabase()
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            guard Self.isCorruption(error) else { throw error }
            // This database contains only disposable derived state. If it is
            // corrupt, discard it and rebuild from sources. Operational errors
            // (for example SQLITE_BUSY or a permissions failure) never delete it.
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            database = try Self.openDatabase(at: databaseURL)
            do {
                try configureDatabase()
            } catch {
                sqlite3_close(database)
                database = nil
                throw error
            }
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(database)
            throw StoreError.openFailed(code: result, message: message)
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode = WAL")
        try initializeSchema()
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("agent-usage-index.sqlite")
    }

    func record(source: String, key: String) throws -> AgentUsageIndexRecord? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT metadata, payload FROM agent_usage_entries WHERE source = ?1 AND entry_key = ?2"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(source, to: statement, at: 1)
        try bind(key, to: statement, at: 2)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return AgentUsageIndexRecord(
                metadata: data(from: statement, column: 0),
                payload: data(from: statement, column: 1)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    func records(source: String) throws -> [String: AgentUsageIndexRecord] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT entry_key, metadata, payload FROM agent_usage_entries WHERE source = ?1"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(source, to: statement, at: 1)

        var records: [String: AgentUsageIndexRecord] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let key = sqlite3_column_text(statement, 0) else {
                    throw StoreError.sqlite(code: SQLITE_CORRUPT, message: "Index entry had a null key")
                }
                records[String(cString: key)] = AgentUsageIndexRecord(
                    metadata: data(from: statement, column: 1),
                    payload: data(from: statement, column: 2)
                )
            case SQLITE_DONE:
                return records
            default:
                throw sqliteError()
            }
        }
    }

    func cursor(source: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        try prepare("SELECT payload FROM agent_usage_cursors WHERE source = ?1", into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(source, to: statement, at: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return data(from: statement, column: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    /// Applies one source's derived entries and cursor as a single transaction.
    /// Parsing and source-file reads are expected to happen before calling this method.
    func apply(
        source: String,
        upserts: [String: AgentUsageIndexRecord],
        removals: Set<String>,
        cursor: Data?
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for key in removals {
                var statement: OpaquePointer?
                try prepare("DELETE FROM agent_usage_entries WHERE source = ?1 AND entry_key = ?2", into: &statement)
                defer { sqlite3_finalize(statement) }
                try bind(source, to: statement, at: 1)
                try bind(key, to: statement, at: 2)
                try stepDone(statement)
            }

            for (key, record) in upserts {
                var statement: OpaquePointer?
                try prepare(
                    """
                    INSERT INTO agent_usage_entries (source, entry_key, metadata, payload)
                    VALUES (?1, ?2, ?3, ?4)
                    ON CONFLICT(source, entry_key) DO UPDATE SET metadata = excluded.metadata, payload = excluded.payload
                    """,
                    into: &statement
                )
                defer { sqlite3_finalize(statement) }
                try bind(source, to: statement, at: 1)
                try bind(key, to: statement, at: 2)
                try bind(record.metadata, to: statement, at: 3)
                try bind(record.payload, to: statement, at: 4)
                try stepDone(statement)
            }

            if let cursor {
                var statement: OpaquePointer?
                try prepare(
                    "INSERT INTO agent_usage_cursors (source, payload) VALUES (?1, ?2) ON CONFLICT(source) DO UPDATE SET payload = excluded.payload",
                    into: &statement
                )
                defer { sqlite3_finalize(statement) }
                try bind(source, to: statement, at: 1)
                try bind(cursor, to: statement, at: 2)
                try stepDone(statement)
            }

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func initializeSchema() throws {
        let version = try userVersion()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            if version != 0 && version != Self.schemaVersion {
                try execute("DROP TABLE IF EXISTS agent_usage_entries")
                try execute("DROP TABLE IF EXISTS agent_usage_cursors")
            }
            try execute(
                """
                CREATE TABLE IF NOT EXISTS agent_usage_entries (
                    source TEXT NOT NULL,
                    entry_key TEXT NOT NULL,
                    metadata BLOB NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (source, entry_key)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS agent_usage_cursors (
                    source TEXT PRIMARY KEY NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func userVersion() throws -> Int {
        var statement: OpaquePointer?
        try prepare("PRAGMA user_version", into: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw StoreError.sqlite(code: sqlite3_errcode(database), message: message)
        }
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(_ data: Data, to statement: OpaquePointer?, at index: Int32) throws {
        let result = data.withUnsafeBytes { bytes in
            if data.isEmpty {
                return sqlite3_bind_zeroblob(statement, index, 0)
            }
            return sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), Self.transientDestructor)
        }
        guard result == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func data(from statement: OpaquePointer?, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func sqliteError() -> StoreError {
        StoreError.sqlite(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }

    private static func isCorruption(_ error: Error) -> Bool {
        let code: Int32
        switch error {
        case let StoreError.openFailed(errorCode, _), let StoreError.sqlite(errorCode, _):
            code = errorCode & 0xFF
        default:
            return false
        }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
