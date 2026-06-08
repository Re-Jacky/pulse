import XCTest
@testable import pulse

final class OpenCodeUsageModelsTests: XCTestCase {
    func testSessionTotalTokensAddsEveryTokenBucket() {
        let session = OpenCodeSessionRecord(
            id: "ses_1",
            title: "Agent feature",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "deepseek-v4-flash-free",
            modelVariant: "default",
            inputTokens: 120,
            outputTokens: 30,
            reasoningTokens: 8,
            cacheReadTokens: 400,
            cacheWriteTokens: 16,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(session.totalTokens, 574)
    }

    func testProjectOptionsAreRankedByTotalTokensDescending() {
        let low = OpenCodeSessionRecord(
            id: "ses_low",
            title: "Low",
            directory: "/Users/zyao/Desktop/low-project",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "model-a",
            modelVariant: nil,
            inputTokens: 10,
            outputTokens: 10,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let high = OpenCodeSessionRecord(
            id: "ses_high",
            title: "High",
            directory: "/Users/zyao/Desktop/high-project",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "model-b",
            modelVariant: nil,
            inputTokens: 100,
            outputTokens: 50,
            reasoningTokens: 10,
            cacheReadTokens: 500,
            cacheWriteTokens: 0,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4)
        )

        let snapshot = OpenCodeUsageSnapshot(sessions: [low, high])

        XCTAssertEqual(snapshot.projectOptions.map(\.shortName), ["high-project", "low-project"])
    }

    func testModelBreakdownAggregatesByProviderModelAndVariant() {
        let a = OpenCodeSessionRecord(
            id: "ses_a",
            title: "A",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "build",
            modelProviderID: "github-copilot",
            modelID: "claude-sonnet-4.6",
            modelVariant: "default",
            inputTokens: 200,
            outputTokens: 20,
            reasoningTokens: 0,
            cacheReadTokens: 1000,
            cacheWriteTokens: 0,
            cost: 1.5,
            createdAt: Date(timeIntervalSince1970: 5),
            updatedAt: Date(timeIntervalSince1970: 6)
        )

        let b = OpenCodeSessionRecord(
            id: "ses_b",
            title: "B",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "general",
            modelProviderID: "github-copilot",
            modelID: "claude-sonnet-4.6",
            modelVariant: "default",
            inputTokens: 100,
            outputTokens: 10,
            reasoningTokens: 0,
            cacheReadTokens: 200,
            cacheWriteTokens: 0,
            cost: 0.5,
            createdAt: Date(timeIntervalSince1970: 7),
            updatedAt: Date(timeIntervalSince1970: 8)
        )

        let snapshot = OpenCodeUsageSnapshot(sessions: [a, b])
        let breakdown = snapshot.modelBreakdown(for: .allProjects)

        XCTAssertEqual(breakdown.count, 1)
        XCTAssertEqual(breakdown[0].providerID, "github-copilot")
        XCTAssertEqual(breakdown[0].modelID, "claude-sonnet-4.6")
        XCTAssertEqual(breakdown[0].variant, "default")
        XCTAssertEqual(breakdown[0].summary.totalTokens, 1530)
        XCTAssertEqual(breakdown[0].summary.cost, 2.0, accuracy: 0.0001)
    }

    func testSessionScopeSummaryUsesOnlySelectedSession() {
        let one = OpenCodeSessionRecord(
            id: "ses_1",
            title: "One",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "build",
            modelProviderID: "opencode",
            modelID: "model-a",
            modelVariant: nil,
            inputTokens: 20,
            outputTokens: 5,
            reasoningTokens: 1,
            cacheReadTokens: 100,
            cacheWriteTokens: 2,
            cost: 0,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 12)
        )

        let two = OpenCodeSessionRecord(
            id: "ses_2",
            title: "Two",
            directory: "/Users/zyao/Desktop/pulse",
            agent: "general",
            modelProviderID: "opencode",
            modelID: "model-b",
            modelVariant: nil,
            inputTokens: 999,
            outputTokens: 999,
            reasoningTokens: 999,
            cacheReadTokens: 999,
            cacheWriteTokens: 999,
            cost: 9,
            createdAt: Date(timeIntervalSince1970: 13),
            updatedAt: Date(timeIntervalSince1970: 14)
        )

        let snapshot = OpenCodeUsageSnapshot(sessions: [one, two])
        let summary = snapshot.summary(for: .session(projectDirectory: "/Users/zyao/Desktop/pulse", sessionID: "ses_1"))

        XCTAssertEqual(summary.totalTokens, 128)
        XCTAssertEqual(summary.inputTokens, 20)
        XCTAssertEqual(summary.outputTokens, 5)
        XCTAssertEqual(summary.reasoningTokens, 1)
        XCTAssertEqual(summary.cacheReadTokens, 100)
        XCTAssertEqual(summary.cacheWriteTokens, 2)
        XCTAssertEqual(summary.sessionsCount, 1)
    }
}
