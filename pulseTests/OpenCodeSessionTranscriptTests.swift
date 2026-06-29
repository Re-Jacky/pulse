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
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertEqual(action, .openCode(command: "opencode resume ses_1"))
    }

    private func loadOpenCodeTranscriptFixture() throws -> [TranscriptTurn] {
        let databaseURL = try makeDatabase(named: "OpenCodeTranscriptTests.sqlite")
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
            'ses_1', 'project_1', 'Transcript', '/tmp/project', 'build',
            '{"id":"gpt-5.4","providerID":"openai"}',
            0, 0, 0, 0, 0, 0, 1000, 2000
        );
        """)

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
