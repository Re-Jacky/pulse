import Foundation
import Darwin
import SQLite3

struct OpenCodeUsageLoadResult {
    let snapshot: OpenCodeUsageSnapshot
    let dailyBuckets: [OpenCodeDailyBucket]
}

enum OpenCodeUsageQuery {
enum QueryError: Error, Equatable, LocalizedError {
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

static var defaultDatabaseURL: URL {
URL(fileURLWithPath: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
}

static func candidateDatabaseURLs(
environment: [String: String] = ProcessInfo.processInfo.environment,
homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
) -> [URL] {
var candidates: [URL] = []

if let explicitPath = environment["OPENCODE_DB_PATH"], explicitPath.isEmpty == false {
candidates.append(URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath))
}

if let xdgDataHome = environment["XDG_DATA_HOME"], xdgDataHome.isEmpty == false {
candidates.append(
URL(fileURLWithPath: NSString(string: xdgDataHome).expandingTildeInPath)
.appendingPathComponent("opencode")
.appendingPathComponent("opencode.db")
)
}

candidates.append(
homeDirectoryURL
.appendingPathComponent(".local")
.appendingPathComponent("share")
.appendingPathComponent("opencode")
.appendingPathComponent("opencode.db")
)

if let applicationSupportDirectory {
candidates.append(
applicationSupportDirectory
.appendingPathComponent("opencode")
.appendingPathComponent("opencode.db")
)
}

var seenPaths = Set<String>()
return candidates.filter { seenPaths.insert($0.path).inserted }
}

static func resolveDatabaseURL(
environment: [String: String] = ProcessInfo.processInfo.environment,
fileManager: FileManager = .default,
homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
) -> URL {
let candidates = candidateDatabaseURLs(
environment: environment,
homeDirectoryURL: homeDirectoryURL,
applicationSupportDirectory: applicationSupportDirectory
)

let existingCandidates = candidates.filter { fileManager.fileExists(atPath: $0.path) }
guard existingCandidates.isEmpty == false else {
return candidates.first ?? defaultDatabaseURL
}

return existingCandidates.max { lhs, rhs in
let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
return lhsDate < rhsDate
} ?? existingCandidates[0]
}

static func loadSnapshot(databaseURL: URL) throws -> OpenCodeUsageSnapshot {
    try loadUsage(databaseURL: databaseURL).snapshot
}

static func loadDailyBuckets(databaseURL: URL) throws -> [OpenCodeDailyBucket] {
    try loadUsage(databaseURL: databaseURL).dailyBuckets
}

private struct OpenCodeSessionMetadata: Codable, Equatable {
    let title: String
    let directory: String
    let agent: String
    let modelProviderID: String
    let modelID: String
    let modelVariant: String?
    let createdAt: Date
    let updatedAt: Date
    let updatedAtMilliseconds: Int64
    let watermarkMilliseconds: Int64
}

private struct OpenCodeUsageIndexEntry: Codable {
    let watermarkMilliseconds: Int64
    let metadata: OpenCodeSessionMetadata
    let dailyBuckets: [OpenCodeDailyBucket]

    func needsUsageRefresh(for session: OpenCodeSessionMetadata) -> Bool {
        watermarkMilliseconds != session.watermarkMilliseconds
            || metadata.modelProviderID != session.modelProviderID
            || metadata.modelID != session.modelID
            || metadata.modelVariant != session.modelVariant
    }
}

private struct OpenCodeSourceCursor: Codable, Equatable {
    let databaseIdentity: String
    let schemaVersion: Int
    let calendarIdentity: String
    let mainModificationNanoseconds: Int64
    let walModificationNanoseconds: Int64
}

// Loads usage from the Pulse-owned SQLite index and reparses only sessions
// whose source watermark has advanced.
static func loadUsage(
    databaseURL: URL,
    cacheDirectoryURL: URL? = nil,
    indexDatabaseURL: URL? = nil
) throws -> OpenCodeUsageLoadResult {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
        throw QueryError.databaseNotFound(path: databaseURL.path)
    }

    let resolvedIndexURL = indexDatabaseURL
        ?? cacheDirectoryURL?.appendingPathComponent("agent-usage-index.sqlite")
        ?? AgentUsageIndexStore.defaultDatabaseURL()
    let store = try AgentUsageIndexStore(databaseURL: resolvedIndexURL)
    let databaseIdentity = databaseIdentity(for: databaseURL)
    let calendarIdentity = currentCalendarIdentity()
    let mainModificationNanoseconds = modificationTimeNanoseconds(at: databaseURL)
    let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
    let walModificationNanoseconds = modificationTimeNanoseconds(at: walURL)
    let sourceKey = "opencode-\(stableHash(databaseURL.standardizedFileURL.path))"
    let savedCursor = try store.cursor(source: sourceKey).flatMap { try? JSONDecoder().decode(OpenCodeSourceCursor.self, from: $0) }
    var entries: [String: OpenCodeUsageIndexEntry] = [:]
    let storedRecords = try store.records(source: sourceKey)
    for (sessionID, record) in storedRecords {
        if let entry = try? JSONDecoder().decode(OpenCodeUsageIndexEntry.self, from: record.payload) {
            entries[sessionID] = entry
        }
    }

    if let savedCursor,
       savedCursor.databaseIdentity == databaseIdentity,
       savedCursor.mainModificationNanoseconds == mainModificationNanoseconds,
       savedCursor.walModificationNanoseconds == walModificationNanoseconds,
       savedCursor.calendarIdentity == calendarIdentity,
       entries.count == storedRecords.count {
        let metadata = entries.mapValues(\.metadata)
        let dailyBuckets = sortedBuckets(from: entries)
        return OpenCodeUsageLoadResult(
            snapshot: makeSnapshot(dailyBuckets: dailyBuckets, metadata: metadata),
            dailyBuckets: dailyBuckets
        )
    }

    let db = try openReadOnlyDatabase(
        databaseURL: databaseURL,
        includeWAL: walModificationNanoseconds > mainModificationNanoseconds
    )
    defer { sqlite3_close(db) }

    let usesV2Schema = tableExists(db: db, table: "session_v2")
    let sessionTable = usesV2Schema ? "session_v2" : "session"
    let messageTable = usesV2Schema ? "session_message" : "message"
    let schemaVersion = usesV2Schema ? 2 : 1

    let metadata = try loadSessionMetadata(
        db: db,
        sessionTable: sessionTable,
        messageTable: messageTable
    )
    let isCalendarInvalidated = savedCursor?.calendarIdentity != calendarIdentity
    let isCacheCompatible = savedCursor?.databaseIdentity == databaseIdentity
        && savedCursor?.schemaVersion == schemaVersion
        && isCalendarInvalidated == false
    if isCacheCompatible == false {
        entries.removeAll(keepingCapacity: true)
    }

    let currentSessionIDs = Set(metadata.keys)
    let removedSessionIDs = Set(storedRecords.keys).subtracting(currentSessionIDs)
    for sessionID in removedSessionIDs {
        entries.removeValue(forKey: sessionID)
    }

    let changedSessionIDs = metadata.compactMap { sessionID, session -> String? in
        guard let cached = entries[sessionID],
              cached.needsUsageRefresh(for: session) == false else {
            return sessionID
        }
        return nil
    }.sorted()

    let bucketsToRefresh: [OpenCodeDailyBucket]
    let refreshedSessionIDs: [String]
    if entries.isEmpty && metadata.isEmpty == false {
        bucketsToRefresh = try loadMessageBuckets(
            db: db,
            sessionTable: sessionTable,
            messageTable: messageTable,
            usesV2Schema: usesV2Schema,
            sessionIDs: nil
        )
        refreshedSessionIDs = Array(metadata.keys)
    } else if changedSessionIDs.isEmpty {
        bucketsToRefresh = []
        refreshedSessionIDs = []
    } else {
        bucketsToRefresh = try loadMessageBuckets(
            db: db,
            sessionTable: sessionTable,
            messageTable: messageTable,
            usesV2Schema: usesV2Schema,
            sessionIDs: changedSessionIDs
        )
        refreshedSessionIDs = changedSessionIDs
    }

    let refreshedBucketsBySessionID = Dictionary(grouping: bucketsToRefresh, by: \.sessionID)
    for sessionID in refreshedSessionIDs {
        guard let session = metadata[sessionID] else { continue }
        entries[sessionID] = OpenCodeUsageIndexEntry(
            watermarkMilliseconds: session.watermarkMilliseconds,
            metadata: session,
            dailyBuckets: refreshedBucketsBySessionID[sessionID] ?? []
        )
    }

    // Refresh lightweight session metadata even when the message watermark stayed
    // stable; this keeps titles/directories current without parsing message JSON.
    var upserts: [String: AgentUsageIndexRecord] = [:]
    for (sessionID, session) in metadata {
        var entry = entries[sessionID] ?? OpenCodeUsageIndexEntry(
            watermarkMilliseconds: session.watermarkMilliseconds,
            metadata: session,
            dailyBuckets: []
        )
        if entry.metadata != session {
            entry = OpenCodeUsageIndexEntry(
                watermarkMilliseconds: session.watermarkMilliseconds,
                metadata: session,
                dailyBuckets: entry.dailyBuckets
            )
        }
        entries[sessionID] = entry
        let payload = try JSONEncoder().encode(entry)
        upserts[sessionID] = AgentUsageIndexRecord(metadata: Data(), payload: payload)
    }

    let cursor = OpenCodeSourceCursor(
        databaseIdentity: databaseIdentity,
        schemaVersion: schemaVersion,
        calendarIdentity: calendarIdentity,
        mainModificationNanoseconds: mainModificationNanoseconds,
        walModificationNanoseconds: walModificationNanoseconds
    )
    try store.apply(
        source: sourceKey,
        upserts: upserts,
        removals: removedSessionIDs,
        cursor: try JSONEncoder().encode(cursor)
    )

    let dailyBuckets = sortedBuckets(from: entries)
    let snapshot = makeSnapshot(dailyBuckets: dailyBuckets, metadata: metadata)
    return OpenCodeUsageLoadResult(snapshot: snapshot, dailyBuckets: dailyBuckets)
}

private static func sortedBuckets(from entries: [String: OpenCodeUsageIndexEntry]) -> [OpenCodeDailyBucket] {
    entries.values.flatMap(\.dailyBuckets).sorted { lhs, rhs in
        if lhs.sessionID == rhs.sessionID { return lhs.day < rhs.day }
        return lhs.sessionID < rhs.sessionID
    }
}

private static func loadMessageBuckets(
    db: OpaquePointer?,
    sessionTable: String,
    messageTable: String,
    usesV2Schema: Bool,
    sessionIDs: [String]?
) throws -> [OpenCodeDailyBucket] {

    // The model/token fields live inside the message `data` JSON. Extracting them
    // once into a materialized CTE (rather than inline at every projection site)
    // keeps SQLite from re-parsing the large message blob many times per row.
    let messageFilter = usesV2Schema ? "type = 'assistant'" : "json_extract(data, '$.role') = 'assistant'"
    let messageProviderExpr = usesV2Schema
        ? "coalesce(nullif(json_extract(data, '$.model.providerID'), ''), '')"
        : "coalesce(nullif(json_extract(data, '$.providerID'), ''), '')"
    let messageModelExpr = usesV2Schema
        ? "coalesce(nullif(json_extract(data, '$.model.id'), ''), '')"
        : "coalesce(nullif(json_extract(data, '$.modelID'), ''), '')"
    let messageVariantExpr = usesV2Schema
        ? "json_extract(data, '$.model.variant')"
        : "json_extract(data, '$.variant')"
    let sessionPredicate = sessionIDs == nil ? "" : " AND session_id = ?"

    let sql = """
    WITH msg AS MATERIALIZED (
    SELECT session_id,
           time_created,
           \(messageProviderExpr) AS provider_id,
           \(messageModelExpr) AS model_id,
           \(messageVariantExpr) AS model_variant,
           json_extract(data, '$.tokens') AS tokens_json,
           json_extract(data, '$.cost') AS cost
    FROM \(messageTable)
    WHERE \(messageFilter)\(sessionPredicate)
    )
    SELECT m.session_id,
           m.time_created,
           coalesce(nullif(m.provider_id, ''), coalesce(json_extract(s.model, '$.providerID'), '')),
           coalesce(nullif(m.model_id, ''), coalesce(json_extract(s.model, '$.id'), '')),
           nullif(coalesce(nullif(m.model_variant, ''), json_extract(s.model, '$.variant')), ''),
           coalesce(json_extract(m.tokens_json, '$.input'), 0),
           coalesce(json_extract(m.tokens_json, '$.output'), 0),
           coalesce(json_extract(m.tokens_json, '$.reasoning'), 0),
           coalesce(json_extract(m.tokens_json, '$.cache.read'), 0),
           coalesce(json_extract(m.tokens_json, '$.cache.write'), 0),
           coalesce(m.cost, 0)
    FROM msg m
    JOIN \(sessionTable) s ON s.id = m.session_id
    ORDER BY m.session_id, m.time_created
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var bucketsBySessionAndDay: [String: OpenCodeDailyBucket] = [:]
    let calendar = Calendar.current
    var lastDay: (interval: DateInterval, identifier: Int)?

    func consumeRows() throws {
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }

            let sessionID = stringColumn(statement, index: 0)
            let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)
            let day: Int
            // Reuse the actual local-day bounds only within this refresh. The lower
            // bound handles earlier dates in later sessions; the end is exclusive.
            if let lastDay, createdAt >= lastDay.interval.start, createdAt < lastDay.interval.end {
                day = lastDay.identifier
            } else {
                day = agentUsageDayIdentifier(for: createdAt, calendar: calendar)
                lastDay = calendar.dateInterval(of: .day, for: createdAt).map { ($0, day) }
            }
            let modelProviderID = stringColumn(statement, index: 2)
            let modelID = stringColumn(statement, index: 3)
            let modelVariant = optionalStringColumn(statement, index: 4)
            let modelKey = [modelProviderID, modelID, modelVariant ?? ""].joined(separator: "::")
            let key = "\(sessionID)::\(modelKey)::\(day)"
            let existing = bucketsBySessionAndDay[key]

            bucketsBySessionAndDay[key] = OpenCodeDailyBucket(
                sessionID: sessionID,
                day: day,
                modelProviderID: modelProviderID,
                modelID: modelID,
                modelVariant: modelVariant,
                inputTokens: (existing?.inputTokens ?? 0) + Int(sqlite3_column_int64(statement, 5)),
                outputTokens: (existing?.outputTokens ?? 0) + Int(sqlite3_column_int64(statement, 6)),
                reasoningTokens: (existing?.reasoningTokens ?? 0) + Int(sqlite3_column_int64(statement, 7)),
                cacheReadTokens: (existing?.cacheReadTokens ?? 0) + Int(sqlite3_column_int64(statement, 8)),
                cacheWriteTokens: (existing?.cacheWriteTokens ?? 0) + Int(sqlite3_column_int64(statement, 9)),
                requestCount: (existing?.requestCount ?? 0) + 1,
                cost: (existing?.cost ?? 0) + sqlite3_column_double(statement, 10),
                latestActivityAt: max(existing?.latestActivityAt ?? createdAt, createdAt)
            )
        }
    }

    if let sessionIDs {
        for sessionID in sessionIDs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let bindResult = sessionID.withCString { value in
                sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard bindResult == SQLITE_OK else {
                throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
            }
            try consumeRows()
        }
    } else {
        try consumeRows()
    }

    return bucketsBySessionAndDay.values.sorted { lhs, rhs in
        if lhs.sessionID == rhs.sessionID {
            return lhs.day < rhs.day
        }
        return lhs.sessionID < rhs.sessionID
    }
}

private static func databaseIdentity(for databaseURL: URL) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
    let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? "unknown"
    let creationTime = (attributes?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(databaseURL.standardizedFileURL.path)|\(fileNumber)|\(creationTime)"
}

private static func modificationTimeNanoseconds(at url: URL) -> Int64 {
    url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { return -1 }
        return Int64(attributes.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(attributes.st_mtimespec.tv_nsec)
    }
}

private static func openReadOnlyDatabase(databaseURL: URL, includeWAL: Bool) throws -> OpaquePointer? {
    // immutable=1 is the normal path and avoids creating WAL/SHM sidecars. When
    // the WAL is newer than the main file, SQLite must consult it for the latest
    // committed rows; use a read-only mode=ro URI for that case. The source DB
    // and WAL are never opened for writing.
    let readOnlyOptions = includeWAL ? "mode=ro" : "immutable=1"
    let uri = "file://\(databaseURL.path)?\(readOnlyOptions)"
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw QueryError.databaseOpenFailed(message: message)
    }
    return db
}

private static func currentCalendarIdentity() -> String {
    let calendar = Calendar.current
    return "\(calendar.identifier)|\(calendar.timeZone.identifier)"
}

private static func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

private static func loadSessionMetadata(
    db: OpaquePointer?,
    sessionTable: String,
    messageTable: String
) throws -> [String: OpenCodeSessionMetadata] {
    let hasAgentColumn = tableHasColumn(db: db, table: sessionTable, column: "agent")
    let agentExpr = hasAgentColumn ? "coalesce(agent, '')" : "''"
    let sql = """
    SELECT s.id,
           coalesce(s.title, ''),
           coalesce(s.directory, ''),
           \(agentExpr),
           coalesce(json_extract(s.model, '$.providerID'), ''),
           coalesce(json_extract(s.model, '$.id'), ''),
           json_extract(s.model, '$.variant'),
           s.time_created,
           s.time_updated,
           max(s.time_updated, coalesce(max(m.time_updated), 0))
    FROM \(sessionTable) s
    LEFT JOIN \(messageTable) m ON m.session_id = s.id
    GROUP BY s.id
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var metadata: [String: OpenCodeSessionMetadata] = [:]
    while true {
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { break }
        guard stepResult == SQLITE_ROW else {
            throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        let id = stringColumn(statement, index: 0)
        metadata[id] = OpenCodeSessionMetadata(
            title: stringColumn(statement, index: 1),
            directory: stringColumn(statement, index: 2),
            agent: stringColumn(statement, index: 3),
            modelProviderID: stringColumn(statement, index: 4),
            modelID: stringColumn(statement, index: 5),
            modelVariant: optionalStringColumn(statement, index: 6),
            createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 7)) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 8)) / 1000),
            updatedAtMilliseconds: sqlite3_column_int64(statement, 8),
            watermarkMilliseconds: sqlite3_column_int64(statement, 9)
        )
    }
    return metadata
}

private static func makeSnapshot(
    dailyBuckets: [OpenCodeDailyBucket],
    metadata: [String: OpenCodeSessionMetadata]
) -> OpenCodeUsageSnapshot {
    struct Accumulator {
        let sessionID: String
        let providerID: String
        let modelID: String
        let variant: String?
        var inputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var requestCount = 0
        var cost = 0.0
    }

    var accumulators: [String: Accumulator] = [:]
    var sessionsWithBuckets = Set<String>()

    for bucket in dailyBuckets {
        sessionsWithBuckets.insert(bucket.sessionID)
        let key = [bucket.sessionID, bucket.modelProviderID, bucket.modelID, bucket.modelVariant ?? ""].joined(separator: "::")
        var accumulator = accumulators[key] ?? Accumulator(
            sessionID: bucket.sessionID,
            providerID: bucket.modelProviderID,
            modelID: bucket.modelID,
            variant: bucket.modelVariant
        )
        accumulator.inputTokens += bucket.inputTokens
        accumulator.outputTokens += bucket.outputTokens
        accumulator.reasoningTokens += bucket.reasoningTokens
        accumulator.cacheReadTokens += bucket.cacheReadTokens
        accumulator.cacheWriteTokens += bucket.cacheWriteTokens
        accumulator.requestCount += bucket.requestCount
        accumulator.cost += bucket.cost
        accumulators[key] = accumulator
    }

    var records: [OpenCodeSessionRecord] = []
    for (key, accumulator) in accumulators {
        guard let session = metadata[accumulator.sessionID] else { continue }
        records.append(
            OpenCodeSessionRecord(
                id: key,
                title: session.title,
                directory: session.directory,
                agent: session.agent,
                modelProviderID: accumulator.providerID,
                modelID: accumulator.modelID,
                modelVariant: accumulator.variant,
                inputTokens: accumulator.inputTokens,
                outputTokens: accumulator.outputTokens,
                reasoningTokens: accumulator.reasoningTokens,
                cacheReadTokens: accumulator.cacheReadTokens,
                cacheWriteTokens: accumulator.cacheWriteTokens,
                requestCount: accumulator.requestCount,
                cost: accumulator.cost,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
        )
    }

    // Sessions with no assistant messages still surface with zero tokens and the
    // session-level model, mirroring the previous LEFT JOIN behavior.
    for (sessionID, session) in metadata where sessionsWithBuckets.contains(sessionID) == false {
        let key = [sessionID, session.modelProviderID, session.modelID, session.modelVariant ?? ""].joined(separator: "::")
        records.append(
            OpenCodeSessionRecord(
                id: key,
                title: session.title,
                directory: session.directory,
                agent: session.agent,
                modelProviderID: session.modelProviderID,
                modelID: session.modelID,
                modelVariant: session.modelVariant,
                inputTokens: 0,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 0,
                cost: 0,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
        )
    }

    return OpenCodeUsageSnapshot(sessions: records)
}

static func loadTranscript(databaseURL: URL, sessionID: String) throws -> [TranscriptTurn] {
    try loadTranscript(databaseURL: databaseURL, sessionID: sessionID, partialBatchSize: 24, onPartialUpdate: nil)
}

static func loadTranscript(
    databaseURL: URL,
    sessionID: String,
    partialBatchSize: Int = 24,
    onPartialUpdate: (@Sendable ([TranscriptTurn]) -> Void)?
) throws -> [TranscriptTurn] {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
        throw QueryError.databaseNotFound(path: databaseURL.path)
    }

    let uri = openCodeTranscriptDatabaseURI(for: databaseURL)
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw QueryError.databaseOpenFailed(message: message)
    }
    defer { sqlite3_close(db) }

    if tableExists(db: db, table: "session_v2") {
        return try loadV2Transcript(
            db: db,
            sessionID: sessionID,
            partialBatchSize: partialBatchSize,
            onPartialUpdate: onPartialUpdate
        )
    }

    let sql = """
    SELECT m.id,
           m.time_created,
           m.data,
           p.id,
           p.time_created,
           p.data
    FROM message m
    LEFT JOIN part p
      ON p.message_id = m.id
    WHERE m.session_id = ?
    ORDER BY m.time_created ASC, m.id ASC, p.time_created ASC, p.id ASC
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)

    struct TranscriptMessageAccumulator {
        let id: String
        let timestampMilliseconds: Int64
        let object: [String: Any]
        var partObjects: [[String: Any]]
    }

    var turns: [TranscriptTurn] = []
    var currentMessage: TranscriptMessageAccumulator?
    var publishedCount = 0

    func flushCurrentMessage() {
        guard let message = currentMessage else { return }
        guard let turn = transcriptTurnFromOpenCodeMessage(
            id: message.id,
            timestampMilliseconds: message.timestampMilliseconds,
            object: message.object,
            partObjects: message.partObjects
        ) else {
            return
        }

        turns.append(turn)

        if let onPartialUpdate,
           partialBatchSize > 0,
           turns.count - publishedCount >= partialBatchSize {
            publishedCount = turns.count
            onPartialUpdate(turns)
        }
    }

    while true {
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { break }
        guard stepResult == SQLITE_ROW else {
            throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        let id = stringColumn(statement, index: 0)
        let timestampMilliseconds = sqlite3_column_int64(statement, 1)
        let payload = stringColumn(statement, index: 2)

        guard
            let data = payload.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let object = jsonObject as? [String: Any]
        else {
            continue
        }

        if currentMessage?.id != id {
            flushCurrentMessage()
            currentMessage = TranscriptMessageAccumulator(
                id: id,
                timestampMilliseconds: timestampMilliseconds,
                object: object,
                partObjects: []
            )
        }

        let partPayload = stringColumn(statement, index: 5)
        if partPayload.isEmpty == false,
           let partData = partPayload.data(using: .utf8),
           let partJSONObject = try? JSONSerialization.jsonObject(with: partData),
           let partObject = partJSONObject as? [String: Any] {
            currentMessage?.partObjects.append(partObject)
        }
    }

    flushCurrentMessage()

    if let onPartialUpdate, turns.count > publishedCount {
        onPartialUpdate(turns)
    }

    return turns
}

private static func loadV2Transcript(
    db: OpaquePointer?,
    sessionID: String,
    partialBatchSize: Int,
    onPartialUpdate: (@Sendable ([TranscriptTurn]) -> Void)?
) throws -> [TranscriptTurn] {
    let sql = """
    SELECT m.id,
           m.time_created,
           m.data,
           m.type
    FROM session_message m
    WHERE m.session_id = ?
    ORDER BY m.time_created ASC, m.seq ASC
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)

    var turns: [TranscriptTurn] = []
    var publishedCount = 0

    while true {
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { break }
        guard stepResult == SQLITE_ROW else {
            throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        let id = stringColumn(statement, index: 0)
        let timestampMilliseconds = sqlite3_column_int64(statement, 1)
        let payload = stringColumn(statement, index: 2)
        let type = stringColumn(statement, index: 3)

        guard
            let data = payload.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let object = jsonObject as? [String: Any],
            let turn = transcriptTurnFromOpenCodeV2Message(
                id: id,
                timestampMilliseconds: timestampMilliseconds,
                type: type,
                object: object
            )
        else {
            continue
        }

        turns.append(turn)

        if let onPartialUpdate,
           partialBatchSize > 0,
           turns.count - publishedCount >= partialBatchSize {
            publishedCount = turns.count
            onPartialUpdate(turns)
        }
    }

    if let onPartialUpdate, turns.count > publishedCount {
        onPartialUpdate(turns)
    }

    return turns
}
}

private func openCodeTranscriptDatabaseURI(for databaseURL: URL) -> String {
    let walPath = databaseURL.path + "-wal"
    if FileManager.default.fileExists(atPath: walPath) {
        return "file://\(databaseURL.path)"
    }

    return "file://\(databaseURL.path)?immutable=1"
}

private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
guard let value = sqlite3_column_text(statement, index) else { return "" }
return String(cString: value)
}

private func optionalStringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
let value = stringColumn(statement, index: index)
return value.isEmpty ? nil : value
}

private func tableExists(db: OpaquePointer?, table: String) -> Bool {
    let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, (table as NSString).utf8String, -1, nil)
    return sqlite3_step(statement) == SQLITE_ROW
}

private func tableHasColumn(db: OpaquePointer?, table: String, column: String) -> Bool {
    let pragma = "PRAGMA table_info(\(table))"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let namePtr = sqlite3_column_text(stmt, 1) {
            let name = String(cString: namePtr)
            if name == column { return true }
        }
    }
    return false
}

private func transcriptTurnFromOpenCodeMessage(
    id: String,
    timestampMilliseconds: Int64,
    object: [String: Any],
    partObjects: [[String: Any]] = []
) -> TranscriptTurn? {
    let role = transcriptRole(from: object["role"] as? String)
    guard role == .user || role == .assistant || role == .system else {
        return nil
    }

    let text = extractTranscriptText(from: object, partObjects: partObjects)
    guard let text, text.isEmpty == false else {
        return nil
    }

    let timestamp = timestampMilliseconds > 0
        ? Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1000)
        : nil

    return TranscriptTurn(id: id, role: role, text: text, timestamp: timestamp)
}

private func transcriptTurnFromOpenCodeV2Message(
    id: String,
    timestampMilliseconds: Int64,
    type: String,
    object: [String: Any]
) -> TranscriptTurn? {
    let role: TranscriptTurnRole
    switch type {
    case "user": role = .user
    case "assistant": role = .assistant
    case "system": role = .system
    default: return nil
    }

    let text: String?
    if role == .assistant {
        text = openCodeV2AssistantText(from: object)
    } else {
        text = transcriptTextValue(from: object["text"])
    }

    guard let text, text.isEmpty == false else {
        return nil
    }

    let timestamp = timestampMilliseconds > 0
        ? Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1000)
        : nil

    return TranscriptTurn(id: id, role: role, text: text, timestamp: timestamp)
}

private func openCodeV2AssistantText(from object: [String: Any]) -> String? {
    guard let content = object["content"] as? [[String: Any]] else {
        return transcriptTextValue(from: object["text"])
    }

    let joined = content
        .compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return transcriptTextValue(from: part["text"])
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return joined.isEmpty ? nil : joined
}

private func transcriptRole(from value: String?) -> TranscriptTurnRole {
    guard let value else { return .unknown }
    switch value {
    case "user": return .user
    case "assistant": return .assistant
    case "system": return .system
    default: return .unknown
    }
}

private func extractTranscriptText(from object: [String: Any], partObjects: [[String: Any]] = []) -> String? {
    if partObjects.isEmpty == false,
       let partText = transcriptTextValue(from: partObjects) {
        return partText
    }

    return transcriptTextValue(from: object)
}

private func transcriptTextValue(from value: Any?) -> String? {
    switch value {
    case let text as String:
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case let object as [String: Any]:
        if let type = object["type"] as? String,
           ignoredTranscriptPartTypes.contains(type) {
            return nil
        }

        if let text = transcriptTextValue(from: object["text"]) {
            return text
        }

        if let content = transcriptTextValue(from: object["content"]) {
            return content
        }

        return nil
    case let items as [[String: Any]]:
        let joined = items
            .compactMap { transcriptTextValue(from: $0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    case let items as [Any]:
        let joined = items
            .compactMap { transcriptTextValue(from: $0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    default:
        return nil
    }
}

private let ignoredTranscriptPartTypes: Set<String> = [
    "step-start",
    "step-finish"
]
