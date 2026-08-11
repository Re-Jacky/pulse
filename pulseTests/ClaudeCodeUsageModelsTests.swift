import XCTest
@testable import Pulse

final class ClaudeCodeUsageModelsTests: XCTestCase {
    private func makeSession(id: String, cwd: String, model: String, tokens: Int, updatedAt: TimeInterval) -> ClaudeCodeSessionRecord {
        ClaudeCodeSessionRecord(
            id: id,
            title: "Session \(id)",
            cwd: cwd,
            model: model,
            modelProvider: "Claude",
            tokensUsed: tokens,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    func testSnapshotSummarizesAllProjects() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "s1", cwd: "/tmp/a", model: "sonnet", tokens: 100, updatedAt: 2_000),
            makeSession(id: "s2", cwd: "/tmp/b", model: "opus", tokens: 50, updatedAt: 3_000)
        ])
        let summary = snapshot.summary(for: .allProjects)
        XCTAssertEqual(summary.totalTokens, 150)
        XCTAssertEqual(summary.sessionsCount, 2)
        XCTAssertEqual(summary.lastUpdated, Date(timeIntervalSince1970: 3_000))
    }

    func testSnapshotSortsSessionsNewestFirst() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "old", cwd: "/tmp/a", model: "sonnet", tokens: 1, updatedAt: 2_000),
            makeSession(id: "new", cwd: "/tmp/a", model: "sonnet", tokens: 2, updatedAt: 4_000)
        ])
        XCTAssertEqual(snapshot.sessions.map(\.id), ["new", "old"])
    }

    func testProjectOptionsGroupByDirectorySortedByTokens() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "s1", cwd: "/tmp/a", model: "sonnet", tokens: 100, updatedAt: 2_000),
            makeSession(id: "s2", cwd: "/tmp/b", model: "sonnet", tokens: 50, updatedAt: 3_000)
        ])
        XCTAssertEqual(snapshot.projectOptions.map(\.shortName), ["a", "b"])
        XCTAssertEqual(snapshot.projectOptions.map(\.summary.totalTokens), [100, 50])
    }

    func testModelAndProviderBreakdown() {
        let snapshot = ClaudeCodeUsageSnapshot(sessions: [
            makeSession(id: "s1", cwd: "/tmp/a", model: "sonnet", tokens: 100, updatedAt: 2_000),
            makeSession(id: "s2", cwd: "/tmp/b", model: "opus", tokens: 50, updatedAt: 3_000)
        ])
        XCTAssertEqual(snapshot.modelBreakdown(for: .allProjects).map(\.model), ["sonnet", "opus"])
        XCTAssertEqual(snapshot.providerBreakdown(for: .allProjects).map(\.provider), ["Claude"])
    }

    func testDailyBucketMergingSumsAndTakesMaxActivity() {
        let bucketA = ClaudeCodeDailyBucket.zero(sessionID: "s1", day: 100)
        let bucketB = ClaudeCodeDailyBucket(
            sessionID: "s1", day: 100,
            inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 1,
            totalTokens: 16, requestCount: 1,
            latestActivityAt: Date(timeIntervalSince1970: 5_000)
        )
        let merged = bucketA.merging(bucketB)
        XCTAssertEqual(merged.inputTokens, 10)
        XCTAssertEqual(merged.totalTokens, 16)
        XCTAssertEqual(merged.requestCount, 1)
        XCTAssertEqual(merged.latestActivityAt, Date(timeIntervalSince1970: 5_000))
    }
}
