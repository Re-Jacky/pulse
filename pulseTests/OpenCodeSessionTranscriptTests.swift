import XCTest
import SQLite3
@testable import Pulse

final class OpenCodeSessionTranscriptTests: XCTestCase {
    func testOpenCodeTranscriptLoaderReturnsUserAndAssistantTurnsInOrder() throws {
        let transcript = try loadOpenCodeTranscriptFixture()

        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.text), ["Fix the tests", "I updated the failing cases."])
    }

    func testOpenCodeResumeActionUsesSourceNativeCommand() {
        let action = SessionManagementRepository().resumeAction(
            for: ManagedSessionSummary(
                id: "opencode::ses_1::openai::gpt-5.4::default",
                source: .openCode,
                rawSessionID: "ses_1",
                title: "Transcript",
                projectPath: "/tmp/project",
                projectName: "project",
                subtitle: "openai / gpt-5.4",
                updatedAt: Date(timeIntervalSince1970: 2_000),
                transcriptURL: nil
            )
        )

        XCTAssertEqual(action, .openCode(command: "opencode --session ses_1"))
    }

    func testOpenCodeTranscriptLoaderSupportsStructuredContentItemTypes() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeTranscriptStructuredTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try createTranscriptSchema(in: db)
        try insertTranscriptSession(into: db, sessionID: "ses_1")
        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 1000, 1000,
         '{"role":"user","content":[{"type":"input_text","text":"Fix the tests"}]}'),
        ('msg_2', 'ses_1', 2000, 2000,
         '{"role":"assistant","content":[{"type":"output_text","text":"I updated the failing cases."}]}');
        """)

        let transcript = try OpenCodeUsageQuery.loadTranscript(databaseURL: databaseURL, sessionID: "ses_1")

        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.text), ["Fix the tests", "I updated the failing cases."])
    }

    func testOpenCodeTranscriptLoaderFallsBackToNestedContentStrings() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeTranscriptNestedContentTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try createTranscriptSchema(in: db)
        try insertTranscriptSession(into: db, sessionID: "ses_1")
        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 1000, 1000,
         '{"role":"assistant","content":[{"type":"tool_result","content":"Compiled successfully"}]}');
        """)

        let transcript = try OpenCodeUsageQuery.loadTranscript(databaseURL: databaseURL, sessionID: "ses_1")

        XCTAssertEqual(transcript.map(\.text), ["Compiled successfully"])
    }

    func testOpenCodeTranscriptLoaderReadsConversationTextFromPartRows() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeTranscriptPartRowsTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try createTranscriptSchema(in: db)
        try insertTranscriptSession(into: db, sessionID: "ses_1")
        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 1000, 1000, '{"role":"user"}'),
        ('msg_2', 'ses_1', 2000, 2000, '{"role":"assistant"}');
        """)
        try execute(db, sql: """
        insert into part (id, message_id, session_id, time_created, time_updated, data) values
        ('prt_1', 'msg_1', 'ses_1', 1001, 1001, '{"type":"text","text":"Fix the tests"}'),
        ('prt_2', 'msg_2', 'ses_1', 2001, 2001, '{"type":"step-start"}'),
        ('prt_3', 'msg_2', 'ses_1', 2002, 2002, '{"type":"text","text":"I updated the failing cases."}'),
        ('prt_4', 'msg_2', 'ses_1', 2003, 2003, '{"type":"step-finish","reason":"stop"}');
        """)

        let transcript = try OpenCodeUsageQuery.loadTranscript(databaseURL: databaseURL, sessionID: "ses_1")

        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.text), ["Fix the tests", "I updated the failing cases."])
    }

    func testOpenCodeTranscriptLoaderPublishesPartialTurnsWhileLoading() throws {
        let databaseURL = try makeDatabase(named: "OpenCodeTranscriptPartialRowsTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try createTranscriptSchema(in: db)
        try insertTranscriptSession(into: db, sessionID: "ses_1")
        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 1000, 1000, '{"role":"user","content":[{"type":"text","text":"One"}]}'),
        ('msg_2', 'ses_1', 2000, 2000, '{"role":"assistant","content":[{"type":"text","text":"Two"}]}'),
        ('msg_3', 'ses_1', 3000, 3000, '{"role":"user","content":[{"type":"text","text":"Three"}]}');
        """)

        var partialBatches: [[TranscriptTurn]] = []
        let transcript = try OpenCodeUsageQuery.loadTranscript(
            databaseURL: databaseURL,
            sessionID: "ses_1",
            partialBatchSize: 2,
            onPartialUpdate: { turns in
                partialBatches.append(turns)
            }
        )

        XCTAssertEqual(transcript.map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(partialBatches.count, 2)
        XCTAssertEqual(partialBatches[0].map(\.text), ["One", "Two"])
        XCTAssertEqual(partialBatches[1].map(\.text), ["One", "Two", "Three"])
    }

    private func loadOpenCodeTranscriptFixture() throws -> [TranscriptTurn] {
        let databaseURL = try makeDatabase(named: "OpenCodeTranscriptTests.sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let db = try openWritableDatabase(databaseURL)
        defer { sqlite3_close(db) }

        try createTranscriptSchema(in: db)
        try insertTranscriptSession(into: db, sessionID: "ses_1")

        try execute(db, sql: """
        insert into message (id, session_id, time_created, time_updated, data) values
        ('msg_1', 'ses_1', 1000, 1000,
         '{"role":"user","content":[{"type":"text","text":"Fix the tests"}]}'),
        ('msg_2', 'ses_1', 2000, 2000,
         '{"role":"assistant","content":[{"type":"text","text":"I updated the failing cases."}]}');
        """)

        return try OpenCodeUsageQuery.loadTranscript(databaseURL: databaseURL, sessionID: "ses_1")
    }
}

private func createTranscriptSchema(in db: OpaquePointer?) throws {
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
    create table part (
        id text primary key,
        message_id text not null,
        session_id text not null,
        time_created integer not null,
        time_updated integer not null,
        data text not null
    );
    """)
}

private func insertTranscriptSession(into db: OpaquePointer?, sessionID: String) throws {
    try execute(db, sql: """
    insert into session (
        id, project_id, title, directory, agent, model, cost,
        tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
        time_created, time_updated
    ) values (
        '\(sessionID)', 'project_1', 'Transcript', '/tmp/project', 'build',
        '{"id":"gpt-5.4","providerID":"openai"}',
        0, 0, 0, 0, 0, 0, 1000, 2000
    );
    """)
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
    if sqlite3_open(url.path, &db) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw NSError(domain: "OpenCodeSessionTranscriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return db
}

private func execute(_ db: OpaquePointer?, sql: String) throws {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        throw NSError(domain: "OpenCodeSessionTranscriptTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
