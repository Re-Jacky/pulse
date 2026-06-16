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
}
