import Foundation
import SQLite3
import XCTest
@testable import Pulse

final class AgentUsageIndexStoreTests: XCTestCase {
    func testRecordsAndCursorPersistAcrossStoreReopenAndRemainSourceScoped() throws {
        let databaseURL = makeIndexURL()
        defer { removeDatabase(at: databaseURL) }

        let firstStore = try AgentUsageIndexStore(databaseURL: databaseURL)
        try firstStore.apply(
            source: "opencode",
            upserts: ["session-1": makeRecord(metadata: "mtime-1", payload: "usage-1")],
            removals: [],
            cursor: Data("cursor-1".utf8)
        )
        try firstStore.apply(
            source: "claude",
            upserts: ["session-1": makeRecord(metadata: "file-1", payload: "usage-claude")],
            removals: [],
            cursor: Data("cursor-claude".utf8)
        )

        let reopenedStore = try AgentUsageIndexStore(databaseURL: databaseURL)

        XCTAssertEqual(try reopenedStore.record(source: "opencode", key: "session-1"), makeRecord(metadata: "mtime-1", payload: "usage-1"))
        XCTAssertEqual(try reopenedStore.cursor(source: "opencode"), Data("cursor-1".utf8))
        XCTAssertEqual(try reopenedStore.record(source: "claude", key: "session-1"), makeRecord(metadata: "file-1", payload: "usage-claude"))
        XCTAssertNil(try reopenedStore.record(source: "codex", key: "session-1"))
    }

    func testApplyReplacesEntriesAndPrunesRemovedEntriesWithCursor() throws {
        let databaseURL = makeIndexURL()
        defer { removeDatabase(at: databaseURL) }
        let store = try AgentUsageIndexStore(databaseURL: databaseURL)

        try store.apply(
            source: "claude",
            upserts: [
                "file-a": makeRecord(metadata: "old", payload: "old-usage"),
                "file-b": makeRecord(metadata: "same", payload: "keep-usage")
            ],
            removals: [],
            cursor: Data("old-cursor".utf8)
        )
        try store.apply(
            source: "claude",
            upserts: ["file-a": makeRecord(metadata: "new", payload: "replacement")],
            removals: ["file-b"],
            cursor: Data("new-cursor".utf8)
        )

        XCTAssertEqual(try store.records(source: "claude"), [
            "file-a": makeRecord(metadata: "new", payload: "replacement")
        ])
        XCTAssertEqual(try store.cursor(source: "claude"), Data("new-cursor".utf8))
    }

    func testUnsupportedSchemaVersionStartsWithAnEmptyCurrentIndex() throws {
        let databaseURL = makeIndexURL()
        defer { removeDatabase(at: databaseURL) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)

        let store = try AgentUsageIndexStore(databaseURL: databaseURL)

        XCTAssertTrue(try store.records(source: "opencode").isEmpty)
        XCTAssertNil(try store.cursor(source: "opencode"))
    }

    func testCorruptIndexFileIsRecreatedAsAnEmptyStore() throws {
        let databaseURL = makeIndexURL()
        defer { removeDatabase(at: databaseURL) }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a SQLite database".utf8).write(to: databaseURL)

        let store = try AgentUsageIndexStore(databaseURL: databaseURL)

        XCTAssertTrue(try store.records(source: "opencode").isEmpty)
        XCTAssertNil(try store.cursor(source: "opencode"))
    }

    func testConcurrentSourceWritesDoNotLoseRecords() throws {
        let databaseURL = makeIndexURL()
        defer { removeDatabase(at: databaseURL) }
        let store = try AgentUsageIndexStore(databaseURL: databaseURL)
        let failures = NSLock()
        var writeFailed = false

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                let writer = try AgentUsageIndexStore(databaseURL: databaseURL)
                try writer.apply(
                    source: index.isMultiple(of: 2) ? "codex" : "claude",
                    upserts: ["entry-\(index)": makeRecord(metadata: "m-\(index)", payload: "p-\(index)")],
                    removals: [],
                    cursor: nil
                )
            } catch {
                failures.lock()
                writeFailed = true
                failures.unlock()
            }
        }

        XCTAssertFalse(writeFailed)
        XCTAssertEqual(try store.records(source: "codex").count, 16)
        XCTAssertEqual(try store.records(source: "claude").count, 16)
    }

    private func makeIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-index-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    private func makeRecord(metadata: String, payload: String) -> AgentUsageIndexRecord {
        AgentUsageIndexRecord(metadata: Data(metadata.utf8), payload: Data(payload.utf8))
    }
}
