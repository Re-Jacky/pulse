import Foundation

enum ClaudeCodeUsageQuery {
    enum QueryError: Error, LocalizedError, Equatable {
        case queryStepFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .queryStepFailed(let message): return message
            }
        }
    }

    static let defaultModelProvider = "Claude"

    static func resolveProjectsDirectory(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    static func loadSnapshot(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> ClaudeCodeUsageSnapshot {
        let entries = try loadCachedEntries(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var sessionsByID: [String: SessionAccumulator] = [:]

        for entry in entries {
            sessionsByID[entry.sessionID, default: SessionAccumulator()].merge(entry.accumulator)
        }

        return ClaudeCodeUsageSnapshot(
            sessions: sessionsByID.compactMap { sessionID, accumulator in
                accumulator.sessionRecord(id: sessionID)
            }
        )
    }

    static func loadDailyBuckets(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> [ClaudeCodeDailyBucket] {
        let entries = try loadCachedEntries(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var totalsBySessionAndDay: [String: ClaudeCodeDailyBucket] = [:]

        for entry in entries {
            merge(entry.buckets, into: &totalsBySessionAndDay)
        }

        return totalsBySessionAndDay
            .compactMap { key, bucket in
                let parts = key.split(separator: "::", maxSplits: 1).map(String.init)
                guard parts.count == 2, let day = Int(parts[1]) else { return nil }
                return ClaudeCodeDailyBucket(
                    sessionID: parts[0],
                    day: day,
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    cacheWriteTokens: bucket.cacheWriteTokens,
                    totalTokens: bucket.totalTokens,
                    requestCount: bucket.requestCount,
                    latestActivityAt: bucket.latestActivityAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.day == rhs.day { return lhs.sessionID < rhs.sessionID }
                return lhs.day < rhs.day
            }
    }

    // MARK: - Cached transcript loading

    private struct ParsedTranscript {
        let sessionID: String
        let accumulator: SessionAccumulator
        let buckets: [ClaudeCodeDailyBucket]
    }

    // Single-pass design: each changed transcript is fully parsed exactly once per
    // refresh, producing both its session accumulator and its daily buckets, which
    // are cached together keyed by size+mtime. Unchanged transcripts are metadata-only.
    private static func loadCachedEntries(
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> [ParsedTranscript] {
        let transcriptURLs = candidateTranscriptURLs(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var cache = DailyBucketCache.load(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        var didUpdateCache = false
        var parsed: [ParsedTranscript] = []

        for url in transcriptURLs {
            guard let metadata = TranscriptCacheMetadata(url: url) else {
                if let entry = try parseTranscript(transcriptURL: url) {
                    parsed.append(entry)
                }
                continue
            }

            if let cached = cache.entry(for: metadata) {
                if let sessionID = cached.sessionID, let session = cached.session {
                    parsed.append(ParsedTranscript(sessionID: sessionID, accumulator: session, buckets: cached.buckets))
                }
                continue
            }

            guard let entry = try parseTranscript(transcriptURL: url) else { continue }
            parsed.append(entry)
            cache.setEntry(
                DailyBucketCache.Entry(
                    metadata: metadata,
                    buckets: entry.buckets,
                    sessionID: entry.sessionID,
                    session: entry.accumulator
                ),
                for: metadata.path
            )
            didUpdateCache = true
        }

        if cache.removeEntries(excluding: Set(transcriptURLs.map(\.path))) {
            didUpdateCache = true
        }
        if didUpdateCache {
            cache.save(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        }

        return parsed
    }

    // MARK: - Transcript parsing

    private struct SessionAccumulator: Codable {
        var cwd = ""
        var title: String?
        var lastPrompt: String?
        var modelCounts: [String: Int] = [:]
        var createdAt: Date?
        var updatedAt: Date?
        var totalTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var hasConversation = false
        var transcriptURL: URL?

        mutating func merge(_ other: SessionAccumulator) {
            if cwd.isEmpty { cwd = other.cwd }
            if transcriptURL == nil { transcriptURL = other.transcriptURL }
            if other.title?.isEmpty == false { title = other.title }
            if other.lastPrompt?.isEmpty == false { lastPrompt = other.lastPrompt }
            for (model, count) in other.modelCounts {
                modelCounts[model, default: 0] += count
            }
            if let createdAt = other.createdAt, self.createdAt == nil || createdAt < self.createdAt! {
                self.createdAt = createdAt
            }
            if let updatedAt = other.updatedAt, updatedAt > (self.updatedAt ?? .distantPast) {
                self.updatedAt = updatedAt
            }
            totalTokens += other.totalTokens
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cacheReadTokens += other.cacheReadTokens
            cacheWriteTokens += other.cacheWriteTokens
            hasConversation = hasConversation || other.hasConversation
        }

        func sessionRecord(id: String) -> ClaudeCodeSessionRecord? {
            guard hasConversation else { return nil }
            let resolvedTitle = title?.isEmpty == false
                ? title!
                : (lastPrompt?.isEmpty == false ? lastPrompt! : URL(fileURLWithPath: cwd).lastPathComponent)
            let resolvedModel = modelCounts.max { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key > rhs.key }
                return lhs.value < rhs.value
            }?.key ?? ""
            let createdAt = createdAt ?? .distantPast
            return ClaudeCodeSessionRecord(
                id: id,
                title: resolvedTitle,
                cwd: cwd,
                model: resolvedModel,
                modelProvider: ClaudeCodeUsageQuery.defaultModelProvider,
                tokensUsed: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                createdAt: createdAt,
                updatedAt: updatedAt ?? createdAt,
                transcriptURL: transcriptURL
            )
        }
    }

    private static func parseTranscript(transcriptURL: URL) throws -> ParsedTranscript? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else {
            throw QueryError.queryStepFailed(message: "Failed to read transcript at \(transcriptURL.path)")
        }
        defer { try? handle.close() }

        guard let contents = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }

        var sessionID: String?
        var accumulator = SessionAccumulator()
        var bucketsByKey: [String: ClaudeCodeDailyBucket] = [:]

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let rawObject = try? JSONSerialization.jsonObject(with: data),
                  let object = rawObject as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            if let lineSessionID = (object["sessionId"] as? String) ?? (object["session_id"] as? String),
               lineSessionID.isEmpty == false {
                sessionID = lineSessionID
            }

            if type == "ai-title", let aiTitle = object["aiTitle"] as? String, aiTitle.isEmpty == false {
                accumulator.title = aiTitle
                continue
            }

            if type == "last-prompt", let lastPrompt = object["lastPrompt"] as? String, lastPrompt.isEmpty == false {
                accumulator.lastPrompt = lastPrompt
                continue
            }

            // createdAt/updatedAt track the whole transcript (session start), mirroring
            // OpenCode's MIN(s.time_created) / MAX(s.time_updated) and Codex's created_at_ms.
            let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
            if let timestamp {
                if accumulator.createdAt == nil || timestamp < accumulator.createdAt! {
                    accumulator.createdAt = timestamp
                }
                if accumulator.updatedAt == nil || timestamp > accumulator.updatedAt! {
                    accumulator.updatedAt = timestamp
                }
            }

            if type == "user",
               let message = object["message"] as? [String: Any],
               (message["role"] as? String) == "user" {
                accumulator.hasConversation = true
                if accumulator.cwd.isEmpty, let cwd = object["cwd"] as? String {
                    accumulator.cwd = cwd
                }
                continue
            }

            // Assistant counting is gated on a parseable timestamp intentionally:
            // real transcripts always carry parseable ISO8601 timestamps, and the
            // fractional-seconds + plain ISO8601 formatters below cover them.
            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let currentSessionID = sessionID,
                  let timestamp else {
                continue
            }

            if accumulator.cwd.isEmpty, let cwd = object["cwd"] as? String {
                accumulator.cwd = cwd
            }
            if let model = message["model"] as? String, model.isEmpty == false {
                accumulator.modelCounts[model, default: 0] += 1
            }

            let input = int(usage, "input_tokens") ?? 0
            let output = int(usage, "output_tokens") ?? 0
            let cacheRead = int(usage, "cache_read_input_tokens") ?? 0
            let cacheWrite = int(usage, "cache_creation_input_tokens") ?? 0
            let total = input + output + cacheRead + cacheWrite

            accumulator.hasConversation = true
            accumulator.totalTokens += total
            accumulator.inputTokens += input
            accumulator.outputTokens += output
            accumulator.cacheReadTokens += cacheRead
            accumulator.cacheWriteTokens += cacheWrite

            let day = agentUsageDayIdentifier(for: timestamp)
            let key = "\(currentSessionID)::\(day)"
            let deltaBucket = ClaudeCodeDailyBucket(
                sessionID: currentSessionID,
                day: day,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                totalTokens: total,
                requestCount: 1,
                latestActivityAt: timestamp
            )
            let existing = bucketsByKey[key, default: .zero(sessionID: currentSessionID, day: day)]
            bucketsByKey[key] = existing.merging(deltaBucket)
        }

        guard let sessionID, !sessionID.isEmpty else { return nil }
        // main transcript lives at <dir>/<sessionID>.jsonl; subagent files are
        // agent-*.jsonl under a subagents/ dir and must NOT claim the URL
        if transcriptURL.lastPathComponent == "\(sessionID).jsonl" {
            accumulator.transcriptURL = transcriptURL
        }
        return ParsedTranscript(
            sessionID: sessionID,
            accumulator: accumulator,
            buckets: Array(bucketsByKey.values)
        )
    }

    private static func merge(
        _ buckets: some Sequence<ClaudeCodeDailyBucket>,
        into totalsBySessionAndDay: inout [String: ClaudeCodeDailyBucket]
    ) {
        for bucket in buckets {
            let key = "\(bucket.sessionID)::\(bucket.day)"
            let existing = totalsBySessionAndDay[key, default: .zero(sessionID: bucket.sessionID, day: bucket.day)]
            totalsBySessionAndDay[key] = existing.merging(bucket)
        }
    }

    private static func int(_ object: [String: Any], _ key: String) -> Int? {
        (object[key] as? NSNumber)?.intValue
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        ISO8601DateFormatter.claudeCodeUsage.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: - Transcript discovery

    private static func candidateTranscriptURLs(homeDirectoryURL: URL, fileManager: FileManager) -> [URL] {
        var urls: [URL] = []
        collectTranscriptURLs(
            in: resolveProjectsDirectory(homeDirectoryURL: homeDirectoryURL),
            fileManager: fileManager,
            into: &urls
        )
        return urls
    }

    private static func collectTranscriptURLs(
        in directory: URL,
        fileManager: FileManager,
        into urls: inout [URL]
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // Claude Code nests subagent (Task-tool) transcripts under
                // <encoded-cwd>/<sessionId>/subagents/agent-<id>.jsonl; recurse
                // without a depth cap so those are scanned too.
                collectTranscriptURLs(in: url, fileManager: fileManager, into: &urls)
                continue
            }
            if url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
    }

    // MARK: - Cache

    private struct TranscriptCacheMetadata: Codable, Equatable {
        let path: String
        let size: Int
        let modificationTime: TimeInterval

        init?(url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modificationDate = values.contentModificationDate else {
                return nil
            }
            self.path = url.path
            self.size = size
            self.modificationTime = modificationDate.timeIntervalSince1970
        }
    }

    private struct DailyBucketCache: Codable {
        struct Entry: Codable {
            let metadata: TranscriptCacheMetadata
            let buckets: [ClaudeCodeDailyBucket]
            let sessionID: String?
            let session: SessionAccumulator?
        }

        private static let version = 2
        private var version: Int
        private var entriesByPath: [String: Entry]

        static func load(homeDirectoryURL: URL, fileManager: FileManager) -> DailyBucketCache {
            guard let data = try? Data(contentsOf: cacheURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)),
                  let cache = try? JSONDecoder().decode(DailyBucketCache.self, from: data),
                  cache.version == version else {
                return DailyBucketCache(version: version, entriesByPath: [:])
            }
            return cache
        }

        func entry(for metadata: TranscriptCacheMetadata) -> Entry? {
            guard let entry = entriesByPath[metadata.path], entry.metadata == metadata else { return nil }
            return entry
        }

        mutating func setEntry(_ entry: Entry, for path: String) {
            entriesByPath[path] = entry
        }

        mutating func removeEntries(excluding paths: Set<String>) -> Bool {
            let originalCount = entriesByPath.count
            entriesByPath = entriesByPath.filter { paths.contains($0.key) }
            return entriesByPath.count != originalCount
        }

        func save(homeDirectoryURL: URL, fileManager: FileManager) {
            let url = Self.cacheURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }

        private static func cacheURL(homeDirectoryURL: URL, fileManager: FileManager) -> URL {
            let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            return baseURL
                .appendingPathComponent("Pulse", isDirectory: true)
                .appendingPathComponent("claude-code-transcript-cache-\(stableHash(homeDirectoryURL.path))-v\(version).json")
        }

        private static func stableHash(_ value: String) -> String {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(hash, radix: 16)
        }
    }
}

private extension ISO8601DateFormatter {
    static let claudeCodeUsage: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
