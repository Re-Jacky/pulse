import Foundation
import SQLite3

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

static func loadDailySnapshot(databaseURL: URL, range: AgentTimeRange) throws -> OpenCodeUsageSnapshot {
guard range != .allTime else {
return try loadSnapshot(databaseURL: databaseURL)
}

guard FileManager.default.fileExists(atPath: databaseURL.path) else {
throw QueryError.databaseNotFound(path: databaseURL.path)
}

let uri = "file://\(databaseURL.path)?immutable=1"
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
sqlite3_close(db)
throw QueryError.databaseOpenFailed(message: message)
}
defer { sqlite3_close(db) }

let now = Date()
let startTime: Date
switch range {
case .today:
startTime = Calendar.current.startOfDay(for: now)
case .last7Days:
startTime = now.addingTimeInterval(-7 * 24 * 60 * 60)
case .last30Days:
startTime = now.addingTimeInterval(-30 * 24 * 60 * 60)
case .allTime:
startTime = Date.distantPast
}

let startMillis = Int64(startTime.timeIntervalSince1970 * 1000)

let sql = """
SELECT
s.id,
s.title,
s.directory,
coalesce(s.agent, ''),
coalesce(nullif(json_extract(m.data, '$.providerID'), ''), coalesce(json_extract(s.model, '$.providerID'), '')),
coalesce(nullif(json_extract(m.data, '$.modelID'), ''), coalesce(json_extract(s.model, '$.id'), '')),
nullif(coalesce(json_extract(m.data, '$.variant'), json_extract(s.model, '$.variant')), ''),
SUM(coalesce(json_extract(m.data, '$.tokens.input'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.output'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.reasoning'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.cache.read'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.cache.write'), 0)),
COUNT(m.id) as request_count,
SUM(coalesce(json_extract(m.data, '$.cost'), 0)),
MIN(s.time_created),
MAX(s.time_updated)
FROM session s
JOIN message m ON m.session_id = s.id
WHERE json_extract(m.data, '$.role') = 'assistant'
AND json_extract(m.data, '$.time.created') >= ?
GROUP BY s.id, coalesce(nullif(json_extract(m.data, '$.providerID'), ''), coalesce(json_extract(s.model, '$.providerID'), '')), coalesce(nullif(json_extract(m.data, '$.modelID'), ''), coalesce(json_extract(s.model, '$.id'), '')), nullif(coalesce(json_extract(m.data, '$.variant'), json_extract(s.model, '$.variant')), '')
ORDER BY MAX(s.time_updated) DESC
"""

var statement: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
}
defer { sqlite3_finalize(statement) }

sqlite3_bind_int64(statement, 1, startMillis)

var sessions: [OpenCodeSessionRecord] = []

while true {
let stepResult = sqlite3_step(statement)
if stepResult == SQLITE_DONE {
break
}

guard stepResult == SQLITE_ROW else {
throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
}

let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 14)) / 1000)
let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 15)) / 1000)

let sessionID = stringColumn(statement, index: 0)
let providerID = stringColumn(statement, index: 4)
let modelIDStr = stringColumn(statement, index: 5)
let variantStr = optionalStringColumn(statement, index: 6) ?? ""
let compoundID = [sessionID, providerID, modelIDStr, variantStr].joined(separator: "::")

sessions.append(
OpenCodeSessionRecord(
id: compoundID,
title: stringColumn(statement, index: 1),
directory: stringColumn(statement, index: 2),
agent: stringColumn(statement, index: 3),
modelProviderID: providerID,
modelID: modelIDStr,
modelVariant: optionalStringColumn(statement, index: 6),
inputTokens: Int(sqlite3_column_int64(statement, 7)),
outputTokens: Int(sqlite3_column_int64(statement, 8)),
reasoningTokens: Int(sqlite3_column_int64(statement, 9)),
cacheReadTokens: Int(sqlite3_column_int64(statement, 10)),
            cacheWriteTokens: Int(sqlite3_column_int64(statement, 11)),
            requestCount: Int(sqlite3_column_int64(statement, 12)),
            cost: sqlite3_column_double(statement, 13),
createdAt: createdAt,
updatedAt: updatedAt
)
)
}

return OpenCodeUsageSnapshot(sessions: sessions)
}

static func loadSnapshot(databaseURL: URL) throws -> OpenCodeUsageSnapshot {
guard FileManager.default.fileExists(atPath: databaseURL.path) else {
throw QueryError.databaseNotFound(path: databaseURL.path)
}

let uri = "file://\(databaseURL.path)?immutable=1"
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
sqlite3_close(db)
throw QueryError.databaseOpenFailed(message: message)
}
defer { sqlite3_close(db) }

let sql = """
select
s.id,
s.title,
s.directory,
coalesce(s.agent, ''),
coalesce(nullif(json_extract(m.data, '$.providerID'), ''), coalesce(json_extract(s.model, '$.providerID'), '')),
coalesce(nullif(json_extract(m.data, '$.modelID'), ''), coalesce(json_extract(s.model, '$.id'), '')),
nullif(coalesce(json_extract(m.data, '$.variant'), json_extract(s.model, '$.variant')), ''),
SUM(coalesce(json_extract(m.data, '$.tokens.input'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.output'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.reasoning'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.cache.read'), 0)),
SUM(coalesce(json_extract(m.data, '$.tokens.cache.write'), 0)),
SUM(CASE WHEN m.id IS NOT NULL AND json_extract(m.data, '$.role') = 'assistant' THEN 1 ELSE 0 END),
SUM(coalesce(CASE WHEN json_extract(m.data, '$.role') = 'assistant' THEN json_extract(m.data, '$.cost') END, 0)),
MIN(s.time_created),
MAX(s.time_updated)
FROM session s
LEFT JOIN message m ON m.session_id = s.id
GROUP BY s.id, coalesce(nullif(json_extract(m.data, '$.providerID'), ''), coalesce(json_extract(s.model, '$.providerID'), '')), coalesce(nullif(json_extract(m.data, '$.modelID'), ''), coalesce(json_extract(s.model, '$.id'), '')), nullif(coalesce(json_extract(m.data, '$.variant'), json_extract(s.model, '$.variant')), '')
ORDER BY MAX(s.time_updated) DESC
"""

var statement: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
}
defer { sqlite3_finalize(statement) }

var sessions: [OpenCodeSessionRecord] = []

while true {
let stepResult = sqlite3_step(statement)
if stepResult == SQLITE_DONE {
break
}

guard stepResult == SQLITE_ROW else {
throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
}

let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 14)) / 1000)
let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 15)) / 1000)

let sessionID = stringColumn(statement, index: 0)
let providerID = stringColumn(statement, index: 4)
let modelIDStr = stringColumn(statement, index: 5)
let variantStr = optionalStringColumn(statement, index: 6) ?? ""
let compoundID = [sessionID, providerID, modelIDStr, variantStr].joined(separator: "::")

sessions.append(
OpenCodeSessionRecord(
id: compoundID,
title: stringColumn(statement, index: 1),
directory: stringColumn(statement, index: 2),
agent: stringColumn(statement, index: 3),
modelProviderID: providerID,
modelID: modelIDStr,
modelVariant: optionalStringColumn(statement, index: 6),
inputTokens: Int(sqlite3_column_int64(statement, 7)),
outputTokens: Int(sqlite3_column_int64(statement, 8)),
reasoningTokens: Int(sqlite3_column_int64(statement, 9)),
cacheReadTokens: Int(sqlite3_column_int64(statement, 10)),
            cacheWriteTokens: Int(sqlite3_column_int64(statement, 11)),
            requestCount: Int(sqlite3_column_int64(statement, 12)),
            cost: sqlite3_column_double(statement, 13),
createdAt: createdAt,
updatedAt: updatedAt
)
)
}

    return OpenCodeUsageSnapshot(sessions: sessions)
}

static func loadDailyBuckets(databaseURL: URL) throws -> [OpenCodeDailyBucket] {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
        throw QueryError.databaseNotFound(path: databaseURL.path)
    }

    let uri = "file://\(databaseURL.path)?immutable=1"
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw QueryError.databaseOpenFailed(message: message)
    }
    defer { sqlite3_close(db) }

    let sql = """
    SELECT m.session_id,
           m.time_created,
           coalesce(nullif(json_extract(m.data, '$.providerID'), ''), coalesce(json_extract(s.model, '$.providerID'), '')),
           coalesce(nullif(json_extract(m.data, '$.modelID'), ''), coalesce(json_extract(s.model, '$.id'), '')),
           nullif(coalesce(json_extract(m.data, '$.variant'), json_extract(s.model, '$.variant')), ''),
           coalesce(json_extract(m.data, '$.tokens.input'), 0),
           coalesce(json_extract(m.data, '$.tokens.output'), 0),
           coalesce(json_extract(m.data, '$.tokens.reasoning'), 0),
           coalesce(json_extract(m.data, '$.tokens.cache.read'), 0),
           coalesce(json_extract(m.data, '$.tokens.cache.write'), 0),
           coalesce(json_extract(m.data, '$.cost'), 0)
    FROM message m
    JOIN session s ON s.id = m.session_id
    WHERE json_extract(m.data, '$.role') = 'assistant'
    ORDER BY m.session_id, m.time_created
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw QueryError.queryPrepareFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var bucketsBySessionAndDay: [String: OpenCodeDailyBucket] = [:]

    while true {
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { break }
        guard stepResult == SQLITE_ROW else {
            throw QueryError.queryStepFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        let sessionID = stringColumn(statement, index: 0)
        let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)
        let day = agentUsageDayIdentifier(for: createdAt)
        let modelProviderID = stringColumn(statement, index: 2)
        let modelID = stringColumn(statement, index: 3)
        let modelVariant = optionalStringColumn(statement, index: 4) ?? ""
        let modelKey = [modelProviderID, modelID, modelVariant].joined(separator: "::")
        let key = "\(sessionID)::\(modelKey)::\(day)"

        let bucket = OpenCodeDailyBucket(
            sessionID: sessionID,
            day: day,
            modelProviderID: stringColumn(statement, index: 2),
            modelID: stringColumn(statement, index: 3),
            modelVariant: optionalStringColumn(statement, index: 4),
            inputTokens: Int(sqlite3_column_int64(statement, 5)),
            outputTokens: Int(sqlite3_column_int64(statement, 6)),
            reasoningTokens: Int(sqlite3_column_int64(statement, 7)),
            cacheReadTokens: Int(sqlite3_column_int64(statement, 8)),
            cacheWriteTokens: Int(sqlite3_column_int64(statement, 9)),
            requestCount: 1,
            cost: sqlite3_column_double(statement, 10),
            latestActivityAt: createdAt
        )

        let existing = bucketsBySessionAndDay[key]
        let latestActivityAt: Date?
        switch (existing?.latestActivityAt, bucket.latestActivityAt) {
        case let (lhs?, rhs?):
            latestActivityAt = max(lhs, rhs)
        case let (lhs?, nil):
            latestActivityAt = lhs
        case let (nil, rhs?):
            latestActivityAt = rhs
        case (nil, nil):
            latestActivityAt = nil
        }

        bucketsBySessionAndDay[key] = OpenCodeDailyBucket(
            sessionID: sessionID,
            day: day,
            modelProviderID: bucket.modelProviderID,
            modelID: bucket.modelID,
            modelVariant: bucket.modelVariant,
            inputTokens: (existing?.inputTokens ?? 0) + bucket.inputTokens,
            outputTokens: (existing?.outputTokens ?? 0) + bucket.outputTokens,
            reasoningTokens: (existing?.reasoningTokens ?? 0) + bucket.reasoningTokens,
            cacheReadTokens: (existing?.cacheReadTokens ?? 0) + bucket.cacheReadTokens,
            cacheWriteTokens: (existing?.cacheWriteTokens ?? 0) + bucket.cacheWriteTokens,
            requestCount: (existing?.requestCount ?? 0) + 1,
            cost: (existing?.cost ?? 0) + bucket.cost,
            latestActivityAt: latestActivityAt
        )
    }

    return bucketsBySessionAndDay.values.sorted { lhs, rhs in
        if lhs.sessionID == rhs.sessionID {
            return lhs.day < rhs.day
        }
        return lhs.sessionID < rhs.sessionID
    }
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
