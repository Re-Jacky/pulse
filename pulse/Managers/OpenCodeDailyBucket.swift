import Foundation

struct OpenCodeDailyBucket: Equatable {
    let sessionID: String
    let day: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cost: Double
    let latestActivityAt: Date?

    init(
        sessionID: String,
        day: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cost: Double,
        latestActivityAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.latestActivityAt = latestActivityAt
    }
}
