import XCTest
import SQLite3
import Darwin
@testable import Pulse

final class OpenCodeUsageQueryTests: XCTestCase {
    func testLoadSnapshotReadsSessionRowsAndParsesModelJSON() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeUsageStoreTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try execute(db, sql: """
        create table session (
            id text primary key,
            project_id text not null,
            title text not null,
            directory text not null,
            agent text,
            model text,
            cost real default 0 not null,
            tokens_input integer default 0 not null,
            tokens_output integer default 0 not null,
            tokens_reasoning integer default 0 not null,
            tokens_cache_read integer default 0 not null,
            tokens_cache_write integer default 0 not null,
            time_created integer not null,
            time_updated integer not null
        );
        """)

        try execute(db, sql: """
        create table message (
            id text primary key,
            session_id text not null,
            time_created integer not null,
            time_updated integer not null,
            data text not null
        );
        """)

        try execute(db, sql: """
        insert into session (
            id, project_id, title, directory, agent, model, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            time_created, time_updated
        ) values (
            'ses_1', 'project_1', 'Pulse agent work', '/Users/zyao/Desktop/pulse', 'build',
            '{"id":"gpt-5.4","providerID":"codex-gpt","variant":"default"}',
            1.25, 100, 50, 10, 1000, 4, 1000, 2000
        );
        """)

        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 1000, 2000,
         '{"role":"assistant","providerID":"codex-gpt","modelID":"gpt-5.4","variant":"default","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":1000,"write":4}},"cost":1.25,"time":{"created":1000}}');
        """)

        let snapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: databaseURL)

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].modelProviderID, "codex-gpt")
        XCTAssertEqual(snapshot.sessions[0].modelID, "gpt-5.4")
        XCTAssertEqual(snapshot.sessions[0].modelVariant, "default")
        XCTAssertEqual(snapshot.summary(for: .allProjects).totalTokens, 1164)
    }

    func testLoadSnapshotThrowsMissingDatabaseError() {
        let missingURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).sqlite")

        XCTAssertThrowsError(try OpenCodeUsageQuery.loadSnapshot(databaseURL: missingURL)) { error in
            guard case OpenCodeUsageQuery.QueryError.databaseNotFound(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(path, missingURL.path)
        }
    }

    func testResolveDatabaseURLPrefersExistingCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let appSupport = root.appendingPathComponent("Library/Application Support")
        let localDB = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let appSupportDB = appSupport.appendingPathComponent("opencode/opencode.db")

        try FileManager.default.createDirectory(at: localDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: localDB.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: appSupportDB.path, contents: Data()))

        let chosen = OpenCodeUsageQuery.resolveDatabaseURL(
            environment: [:],
            fileManager: .default,
            homeDirectoryURL: home,
            applicationSupportDirectory: appSupport
        )

        XCTAssertEqual(chosen.path, appSupportDB.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testCandidateDatabaseURLsIncludeXDGAndCommonFallbacks() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let appSupport = URL(fileURLWithPath: "/tmp/app-support")

        let candidates = OpenCodeUsageQuery.candidateDatabaseURLs(
            environment: ["XDG_DATA_HOME": "/tmp/xdg-data"],
            homeDirectoryURL: home,
            applicationSupportDirectory: appSupport
        )

        XCTAssertEqual(candidates.map(\.path), [
            "/tmp/xdg-data/opencode/opencode.db",
            "/tmp/home/.local/share/opencode/opencode.db",
            "/tmp/app-support/opencode/opencode.db"
        ])
    }

    func testLoadDailyBucketsReturnsPerSessionPerDayTokens() throws {
        let databaseURL = try makeDatabase(named: "DailyBucketTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try execute(db, sql: """
        create table session (
            id text primary key, project_id text not null, title text not null,
            directory text not null, agent text, model text,
            cost real default 0 not null,
            tokens_input integer default 0 not null,
            tokens_output integer default 0 not null,
            tokens_reasoning integer default 0 not null,
            tokens_cache_read integer default 0 not null,
            tokens_cache_write integer default 0 not null,
            time_created integer not null, time_updated integer not null
        );
        """)

        try execute(db, sql: """
        create table message (
            id text primary key, session_id text not null,
            time_created integer not null, time_updated integer not null, data text not null
        );
        """)

        try execute(db, sql: """
        insert into session (id, project_id, title, directory, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            time_created, time_updated)
        values ('ses_1', 'p1', 'Test', '/tmp/test', 0, 0, 0, 0, 0, 0, 1000, 2000);
        """)

        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 172800000, 172800000,
         '{"role":"assistant","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":1000,"write":4}},"cost":0.02,"time":{"created":172800000}}'),
        ('msg_2', 'ses_1', 172800000, 172800000,
         '{"role":"assistant","tokens":{"input":200,"output":30,"reasoning":5,"cache":{"read":500,"write":2}},"cost":0.01,"time":{"created":172800000}}'),
        ('msg_3', 'ses_1', 259200000, 259200000,
         '{"role":"assistant","tokens":{"input":50,"output":20,"reasoning":0,"cache":{"read":200,"write":0}},"cost":0.005,"time":{"created":259200000}}');
        """)

        let buckets = try OpenCodeUsageQuery.loadDailyBuckets(databaseURL: databaseURL)

        XCTAssertEqual(buckets.count, 2)

        let day1Date = Date(timeIntervalSince1970: 172800000.0 / 1000)
        let day2Date = Date(timeIntervalSince1970: 259200000.0 / 1000)
        let day1 = buckets.first { $0.day == agentUsageDayIdentifier(for: day1Date) }
        let day2 = buckets.first { $0.day == agentUsageDayIdentifier(for: day2Date) }

        XCTAssertNotNil(day1)
        XCTAssertEqual(day1?.sessionID, "ses_1")
        XCTAssertEqual(day1?.modelProviderID, "")
        XCTAssertEqual(day1?.modelID, "")
        XCTAssertEqual(day1?.inputTokens, 300)
        XCTAssertEqual(day1?.outputTokens, 80)
        XCTAssertEqual(day1?.reasoningTokens, 15)
        XCTAssertEqual(day1?.cacheReadTokens, 1500)
        XCTAssertEqual(day1?.cacheWriteTokens, 6)
        XCTAssertEqual(day1?.cost ?? 0, 0.03, accuracy: 0.001)

        XCTAssertNotNil(day2)
        XCTAssertEqual(day2?.sessionID, "ses_1")
        XCTAssertEqual(day2?.inputTokens, 50)
        XCTAssertEqual(day2?.cacheReadTokens, 200)
    }

    func testLoadDailyBucketsGroupsMessagesByLocalCalendarDay() throws {
        try withTimeZone("America/Los_Angeles") {
            let databaseURL = try makeDatabase(named: "LocalDayBucketTests.sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let db = try openWritableDatabase(databaseURL)
            defer { sqlite3_close(db) }

            try execute(db, sql: """
            create table session (
                id text primary key, project_id text not null, title text not null,
                directory text not null, agent text, model text,
                cost real default 0 not null,
                tokens_input integer default 0 not null,
                tokens_output integer default 0 not null,
                tokens_reasoning integer default 0 not null,
                tokens_cache_read integer default 0 not null,
                tokens_cache_write integer default 0 not null,
                time_created integer not null, time_updated integer not null
            );
            """)

            try execute(db, sql: """
            create table message (
                id text primary key, session_id text not null,
                time_created integer not null, time_updated integer not null, data text not null
            );
            """)

            try execute(db, sql: """
            insert into session (id, project_id, title, directory, cost,
                tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
                time_created, time_updated)
            values ('ses_1', 'p1', 'Test', '/tmp/test', 0, 0, 0, 0, 0, 0, 1000, 2000);
            """)

            let formatter = ISO8601DateFormatter()
            let firstTimestamp = Int64((formatter.date(from: "2026-06-17T23:55:00Z")?.timeIntervalSince1970 ?? 0) * 1000)
            let secondTimestamp = Int64((formatter.date(from: "2026-06-18T00:05:00Z")?.timeIntervalSince1970 ?? 0) * 1000)

            try execute(db, sql: """
            insert into message (id, session_id, time_created, time_updated, data) values
            ('msg_1', 'ses_1', \(firstTimestamp), \(firstTimestamp),
             '{"role":"assistant","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":1000,"write":4}},"cost":0.02,"time":{"created":\(firstTimestamp)}}'),
            ('msg_2', 'ses_1', \(secondTimestamp), \(secondTimestamp),
             '{"role":"assistant","tokens":{"input":200,"output":30,"reasoning":5,"cache":{"read":500,"write":2}},"cost":0.01,"time":{"created":\(secondTimestamp)}}');
            """)

            let buckets = try OpenCodeUsageQuery.loadDailyBuckets(databaseURL: databaseURL)

            XCTAssertEqual(buckets.count, 1)
            XCTAssertEqual(buckets[0].sessionID, "ses_1")
            XCTAssertEqual(buckets[0].inputTokens, 300)
        XCTAssertEqual(buckets[0].outputTokens, 80)
        XCTAssertEqual(buckets[0].reasoningTokens, 15)
        XCTAssertEqual(buckets[0].cacheReadTokens, 1500)
        XCTAssertEqual(buckets[0].cacheWriteTokens, 6)
        XCTAssertEqual(buckets[0].cost, 0.03, accuracy: 0.001)
    }

    func testLoadDailyBucketsUsesPerMessageModelMetadata() throws {
        let databaseURL = try makeDatabase(named: "DailyBucketModelTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try execute(db, sql: """
        create table session (
            id text primary key, project_id text not null, title text not null,
            directory text not null, agent text, model text,
            cost real default 0 not null,
            tokens_input integer default 0 not null,
            tokens_output integer default 0 not null,
            tokens_reasoning integer default 0 not null,
            tokens_cache_read integer default 0 not null,
            tokens_cache_write integer default 0 not null,
            time_created integer not null, time_updated integer not null
        );
        """)

        try execute(db, sql: """
        create table message (
            id text primary key, session_id text not null,
            time_created integer not null, time_updated integer not null, data text not null
        );
        """)

        try execute(db, sql: """
        insert into session (id, project_id, title, directory, agent, model, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            time_created, time_updated)
        values ('ses_1', 'p1', 'Test', '/tmp/test', 'build',
            '{"id":"step-3.7-flash","providerID":"stepfun"}',
            0, 0, 0, 0, 0, 0, 1000, 2000);
        """)

        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 172800000, 172800000,
         '{"role":"assistant","providerID":"codex-gpt","modelID":"gpt-5.4","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":1000,"write":4}},"cost":0.02,"time":{"created":172800000}}');
        """)

        let buckets = try OpenCodeUsageQuery.loadDailyBuckets(databaseURL: databaseURL)

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].modelProviderID, "codex-gpt")
        XCTAssertEqual(buckets[0].modelID, "gpt-5.4")
    }
    }

    private func makeDatabase(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func openWritableDatabase(_ url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeUsageStoreTests", code: 1)
        }
        return db
    }

    private func execute(_ db: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeUsageStoreTests", code: 2)
        }
    }

    private func withTimeZone(_ identifier: String, perform work: () throws -> Void) throws {
        let previous = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", identifier, 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let previous {
                setenv("TZ", previous, 1)
            } else {
                unsetenv("TZ")
            }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }

        try work()
    }
}
