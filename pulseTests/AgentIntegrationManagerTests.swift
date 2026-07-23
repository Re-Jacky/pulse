import Foundation
import XCTest
@testable import Pulse

final class AgentIntegrationManagerTests: XCTestCase {
    func testStatusesDefaultToNotInstalled() {
        let fs = InMemoryAgentIntegrationFileSystem()
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        let openCodeStatus = manager.status(for: .openCode)
        XCTAssertEqual(openCodeStatus.state, .notInstalled)
        XCTAssertEqual(openCodeStatus.primaryActionTitle, "Install Plugin")
        XCTAssertEqual(openCodeStatus.secondaryActions, [])

        let codexStatus = manager.status(for: .codex)
        XCTAssertEqual(codexStatus.state, .notInstalled)
        XCTAssertEqual(codexStatus.primaryActionTitle, "Install Hook")
        XCTAssertEqual(codexStatus.secondaryActions, [])
    }

    func testCodexInstalledStateRequiresActivationGuidance() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .codexInstalled)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        let status = manager.status(for: .codex)

        XCTAssertEqual(status.state, .installedNeedsActivation)
        XCTAssertEqual(status.primaryActionTitle, "Reinstall")
        XCTAssertEqual(status.secondaryActions, ["Recheck", "Uninstall"])
        XCTAssertTrue(status.guidance.contains("Open the Hooks view in Codex."))
    }

    func testOpenCodeInstalledStateRequiresRestartGuidance() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .openCodeInstalled)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        let status = manager.status(for: .openCode)

        XCTAssertEqual(status.state, .installedNeedsRestart)
        XCTAssertEqual(status.primaryActionTitle, "Reinstall")
        XCTAssertEqual(status.secondaryActions, ["Recheck", "Uninstall"])
        XCTAssertEqual(status.guidance, ["Restart OpenCode so the Pulse plugin is loaded."])
    }

    func testOpenCodeStatusIsOutdatedWhenPluginRevisionIsStale() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .staleOpenCodePlugin)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .openCode).state, .outdated)
    }

    func testOpenCodeStatusIsOutdatedWhenSharedSenderRevisionIsStale() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .staleOpenCodeSender)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .openCode).state, .outdated)
    }

    func testCodexStatusIsOutdatedWhenHookRevisionIsStale() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .staleCodexHook)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .codex).state, .outdated)
    }

    func testCodexStatusIsOutdatedWhenSharedSenderRevisionIsStale() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .staleCodexSender)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .codex).state, .outdated)
    }

    func testUpdateOutdatedIntegrationsReinstallsOnlyStaleManagedIntegrations() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .staleOpenCodePlugin)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        manager.updateOutdatedIntegrations()

        let plugin = try XCTUnwrap(fs.readFile(at: InMemoryAgentIntegrationFileSystem.openCodePluginURL))
        XCTAssertTrue(plugin.contains("PULSE_OPENCODE_PLUGIN_VERSION=opencode-plugin-v1"))
        XCTAssertEqual(manager.status(for: .openCode).state, .installedNeedsRestart)
        XCTAssertEqual(manager.status(for: .codex).state, .notInstalled)
    }

    func testUpdateOutdatedIntegrationsDoesNotInstallMissingIntegrations() throws {
        let fs = InMemoryAgentIntegrationFileSystem()
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        manager.updateOutdatedIntegrations()

        XCTAssertEqual(manager.status(for: .openCode).state, .notInstalled)
        XCTAssertEqual(manager.status(for: .codex).state, .notInstalled)
    }

    func testOpenCodeInstallerWritesPluginThatCallsSharedSender() throws {
        let fs = InMemoryAgentIntegrationFileSystem()
        let installer = OpenCodeIntegrationInstaller(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try installer.install()

        let plugin = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights.ts"))
        XCTAssertTrue(plugin.contains("export default async function"))
        XCTAssertTrue(plugin.contains("event: async"))
        XCTAssertTrue(plugin.contains("session.status"))
        XCTAssertTrue(plugin.contains("session.idle"))
        XCTAssertTrue(plugin.contains("session.error"))
        XCTAssertTrue(plugin.contains("session.updated"))
        XCTAssertTrue(plugin.contains("message.updated"))
        XCTAssertTrue(plugin.contains("parentSessionID"))
        XCTAssertTrue(plugin.contains("isSubagent"))
        XCTAssertTrue(plugin.contains("sessionInfoByID"))
        XCTAssertTrue(plugin.contains("rememberSessionInfo"))
        XCTAssertTrue(plugin.contains("client.session.get"))
        XCTAssertTrue(plugin.contains("path: { id: sessionID }"))
        XCTAssertTrue(plugin.contains("properties?.parentID"))
        XCTAssertTrue(plugin.contains("properties?.parentId"))
        XCTAssertTrue(plugin.contains("const cached = sessionInfoByID.get(sessionID)"))
        XCTAssertTrue(plugin.contains("case \"session.deleted\""))
        XCTAssertTrue(plugin.contains("sessionInfoByID.delete(sessionID)"))
        XCTAssertTrue(plugin.contains("properties?.title"))
        XCTAssertTrue(plugin.contains(".pulse-agent-lights/debug-enabled"))
        XCTAssertTrue(plugin.contains("existsSync(debugEnabledPath) === false"))
        XCTAssertTrue(plugin.contains("pulse-agent-event-sender"))
        XCTAssertTrue(plugin.contains("opencode"))
        XCTAssertTrue(plugin.contains("PULSE_OPENCODE_PLUGIN_VERSION=opencode-plugin-v1"))
    }

    func testOpenCodePluginTreatsOnlySessionParentsAsSubagents() throws {
        let fs = InMemoryAgentIntegrationFileSystem()
        let installer = OpenCodeIntegrationInstaller(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try installer.install()

        let plugin = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights.ts"))
        XCTAssertTrue(plugin.contains("function normalizeParentSessionID(parentSessionID)"))
        XCTAssertTrue(plugin.contains("parentSessionID.startsWith(\"ses_\")"))
        XCTAssertTrue(plugin.contains("const normalizedParentSessionID = normalizeParentSessionID(parentSessionID);"))
        XCTAssertTrue(plugin.contains("const isSubagent = normalizedParentSessionID.length > 0;"))
        XCTAssertTrue(plugin.contains("parentSessionID: normalizedParentSessionID || undefined"))
    }

    func testOpenCodePluginDoesNotPromoteMetadataUpdatesToWorkingState() throws {
        let fs = InMemoryAgentIntegrationFileSystem()
        let installer = OpenCodeIntegrationInstaller(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try installer.install()

        let plugin = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights.ts"))
        XCTAssertFalse(plugin.contains("case \"session.updated\":\n                kind = \"session.working\";"))
        XCTAssertFalse(plugin.contains("case \"message.updated\":\n                kind = \"session.working\";"))
        XCTAssertTrue(plugin.contains("case \"session.updated\":"))
        XCTAssertTrue(plugin.contains("case \"message.updated\":"))
        XCTAssertTrue(plugin.contains("writeDebugLog(\"ignored metadata-only event\""))
    }

    func testSenderTemplateSupportsOptInDebugLog() {
        let script = PulseAgentEventSenderTemplate.script(listenerPort: 45821)

        XCTAssertTrue(script.contains("PULSE_AGENT_SENDER_VERSION=sender-v1"))
        XCTAssertTrue(script.contains(".pulse-agent-lights/debug-enabled"))
        XCTAssertTrue(script.contains(".pulse-agent-lights/logs/pulse-agent-sender.log"))
        XCTAssertTrue(script.contains("raw_payload"))
        XCTAssertTrue(script.contains("positional_args"))
    }

    func testCodexInstallerWritesHooksJsonWithPulseHooks() throws {
        let fs = InMemoryAgentIntegrationFileSystem()
        let installer = CodexIntegrationInstaller(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try installer.install()

        let hook = try XCTUnwrap(fs.readCreatedFile(named: "pulse-agent-lights-hook.sh"))
        XCTAssertTrue(hook.contains("PULSE_CODEX_HOOK_VERSION=codex-hook-v3"))
        XCTAssertTrue(hook.contains("hook_event_name"))
        XCTAssertTrue(hook.contains("parentSessionID"))
        XCTAssertTrue(hook.contains("isSubagent"))
        XCTAssertTrue(hook.contains("payload.session_id"))
        XCTAssertTrue(hook.contains("payload.transcript_path"))
        XCTAssertTrue(hook.contains("payload.thread_id"))
        XCTAssertTrue(hook.contains("payload.turn_id"))
        XCTAssertTrue(hook.contains("payload.turnId"))
        XCTAssertFalse(hook.contains("payload.id"))
        XCTAssertFalse(hook.contains("payload.parent_id"))
        XCTAssertFalse(hook.contains("payload.parentId"))
        XCTAssertTrue(hook.contains("payload.parent_thread_id"))
        XCTAssertTrue(hook.contains("source === \"startup\""))
        XCTAssertTrue(hook.contains("process.exit(0);"))

        let config = try XCTUnwrap(fs.readCreatedFile(named: "hooks.json"))
        XCTAssertTrue(config.contains("\"SessionStart\""))
        XCTAssertTrue(config.contains("\"UserPromptSubmit\""))
        XCTAssertTrue(config.contains("\"SubagentStart\""))
        XCTAssertTrue(config.contains("\"SubagentStop\""))
        XCTAssertTrue(config.contains("\"Stop\""))
        XCTAssertTrue(config.contains("pulse-agent-lights-hook.sh"))
    }

    func testCodexHookNormalizesStableThreadIDsAndParentThreadMetadata() throws {
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        let mainPayload = """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_parent-2026-06-24.jsonl","session_id":"thread_parent","thread_id":"thread_parent","turn_id":"turn_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        let mainNormalizedPayload = try harness.normalizedSenderPayload(from: mainPayload)
        XCTAssertEqual(mainNormalizedPayload["agent"] as? String, "codex")
        XCTAssertEqual(mainNormalizedPayload["sessionID"] as? String, "thread_parent")
        XCTAssertNotEqual(mainNormalizedPayload["sessionID"] as? String, "/Users/zyao/.codex/sessions/thread_parent-2026-06-24.jsonl")
        XCTAssertEqual(mainNormalizedPayload["kind"] as? String, "session.working")
        XCTAssertEqual(mainNormalizedPayload["transcriptPath"] as? String, "/Users/zyao/.codex/sessions/thread_parent-2026-06-24.jsonl")
        XCTAssertEqual(mainNormalizedPayload["turnID"] as? String, "turn_parent")
        XCTAssertNil(mainNormalizedPayload["parentSessionID"])
        XCTAssertNil(mainNormalizedPayload["isSubagent"])

        let childPayload = """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_child-2026-06-24.jsonl","session_id":"thread_child","thread_id":"thread_child","turn_id":"turn_child","thread_source":"subagent","parent_thread_id":"thread_parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"thread_parent"}}},"cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        let childNormalizedPayload = try harness.normalizedSenderPayload(from: childPayload)
        XCTAssertEqual(childNormalizedPayload["agent"] as? String, "codex")
        XCTAssertEqual(childNormalizedPayload["sessionID"] as? String, "thread_child")
        XCTAssertEqual(childNormalizedPayload["kind"] as? String, "session.working")
        XCTAssertEqual(childNormalizedPayload["transcriptPath"] as? String, "/Users/zyao/.codex/sessions/thread_child-2026-06-24.jsonl")
        XCTAssertEqual(childNormalizedPayload["turnID"] as? String, "turn_child")
        XCTAssertEqual(childNormalizedPayload["parentSessionID"] as? String, "thread_parent")
        XCTAssertEqual(childNormalizedPayload["isSubagent"] as? Bool, true)
    }

    func testCodexHookReportsSessionStartWithoutMarkingItWorking() throws {
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        let payload = """
        {"hook_event_name":"SessionStart","session_id":"thread_parent","thread_id":"thread_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        let normalizedPayload = try harness.normalizedSenderPayload(from: payload)
        XCTAssertEqual(normalizedPayload["sessionID"] as? String, "thread_parent")
        XCTAssertEqual(normalizedPayload["kind"] as? String, "session.started")
    }

    func testCodexHookReportsStopAsClosedSession() throws {
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        let payload = """
        {"hook_event_name":"Stop","session_id":"thread_parent","thread_id":"thread_parent","transcript_path":"/tmp/thread_parent.jsonl","turn_id":"turn_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        let normalizedPayload = try harness.normalizedSenderPayload(from: payload)
        XCTAssertEqual(normalizedPayload["sessionID"] as? String, "thread_parent")
        XCTAssertEqual(normalizedPayload["kind"] as? String, "session.closed")
        XCTAssertEqual(normalizedPayload["transcriptPath"] as? String, "/tmp/thread_parent.jsonl")
        XCTAssertEqual(normalizedPayload["turnID"] as? String, "turn_parent")
    }

    func testCodexHookIgnoresSystemThreadEvents() throws {
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        let payload = """
        {"hook_event_name":"UserPromptSubmit","session_id":"system_thread","thread_id":"system_thread","thread_source":"system","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        try harness.runHook(with: payload)
        XCTAssertFalse(harness.didCaptureSenderPayload())
    }

    func testCodexHookUsesTranscriptPathInsteadOfTurnIdentifierForSessionID() throws {
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        let payload = """
        {"hook_event_name":"UserPromptSubmit","transcript_path":"/Users/zyao/.codex/sessions/thread_turn-2026-06-24.jsonl","turn_id":"turn_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        let normalizedPayload = try harness.normalizedSenderPayload(from: payload)
        XCTAssertEqual(normalizedPayload["sessionID"] as? String, "/Users/zyao/.codex/sessions/thread_turn-2026-06-24.jsonl")
        XCTAssertNotEqual(normalizedPayload["sessionID"] as? String, "turn_parent")
    }

    func testCodexHookIgnoresGenericParentIdentifierForSubagentClassification() throws {
        let harness = try CodexHookRegressionHarness()
        defer { harness.cleanup() }

        try harness.installCodexIntegration()
        try harness.installSenderCaptureScript()

        let payload = """
        {"hook_event_name":"UserPromptSubmit","session_id":"thread_child","thread_id":"thread_child","thread_source":"subagent","parent_id":"turn_parent","cwd":"/tmp/pulse"}
        """.data(using: .utf8)!

        let normalizedPayload = try harness.normalizedSenderPayload(from: payload)
        XCTAssertEqual(normalizedPayload["sessionID"] as? String, "thread_child")
        XCTAssertNil(normalizedPayload["parentSessionID"])
        XCTAssertNil(normalizedPayload["isSubagent"])
    }

    func testCodexInstallerPreservesExistingHooksJsonEntries() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .userOwnedCodexHooks)
        let installer = CodexIntegrationInstaller(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try installer.install()

        let config = try XCTUnwrap(fs.readFile(at: InMemoryAgentIntegrationFileSystem.codexHooksURL))
        XCTAssertTrue(config.contains("user-hook.sh"))
        XCTAssertTrue(config.contains("pulse-agent-lights-hook.sh"))
    }

    func testUninstallRemovesPulseHookButPreservesUserHooksJsonEntries() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .codexInstalledWithUserHooks)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.uninstall(.codex)

        let config = try XCTUnwrap(fs.readFile(at: InMemoryAgentIntegrationFileSystem.codexHooksURL))
        XCTAssertTrue(config.contains("user-hook.sh"))
        XCTAssertFalse(config.contains("pulse-agent-lights-hook.sh"))
    }

    func testPrimaryActionInstallsOpenCodeIntegration() throws {
        let fs = InMemoryAgentIntegrationFileSystem()
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.performPrimaryAction(for: .openCode)

        XCTAssertEqual(manager.status(for: .openCode).state, .installedNeedsRestart)
        XCTAssertTrue(fs.openCodePluginStillExists)
    }

    func testSecondaryUninstallActionRemovesManagedCodexFiles() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .codexInstalled)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.performSecondaryAction("Uninstall", for: .codex)

        XCTAssertEqual(manager.status(for: .codex).state, .notInstalled)
        XCTAssertFalse(fs.codexHookStillExists)
    }

    func testReinstallRefreshesManagedOpenCodeFiles() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .outdatedOpenCodeInstall)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.reinstall(.openCode)

        let plugin = try XCTUnwrap(fs.readFile(at: InMemoryAgentIntegrationFileSystem.openCodePluginURL))
        XCTAssertTrue(plugin.contains("PULSE_OPENCODE_PLUGIN_VERSION=opencode-plugin-v1"))
        XCTAssertEqual(manager.status(for: .openCode).state, .installedNeedsRestart)
    }

    func testUninstallPreservesNonPulseManagedFiles() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .userOwnedCodexHook)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.uninstall(.codex)

        XCTAssertTrue(fs.userOwnedCodexHookStillExists)
    }

    func testUninstallPreservesUserOwnedCodexHooksFile() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .userOwnedCodexHooks)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.uninstall(.codex)

        XCTAssertTrue(fs.userOwnedCodexHooksStillExists)
    }

    func testUninstallPreservesSharedSenderWhenOtherAgentStillInstalled() throws {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .bothInstalled)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        try manager.uninstall(.codex)

        XCTAssertTrue(fs.sharedSenderStillExists)
        XCTAssertTrue(fs.openCodePluginStillExists)
        XCTAssertFalse(fs.codexHookStillExists)
    }

    func testOutdatedStateIsReportedWhenManagedMarkerDoesNotMatch() {
        let fs = InMemoryAgentIntegrationFileSystem(seed: .outdatedOpenCodeInstall)
        let manager = AgentIntegrationManager(
            fileSystem: fs,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(manager.status(for: .openCode).state, .outdated)
    }
}

final class CodexHookRegressionHarness: AgentIntegrationManagingFileSystem {
    private let fileManager: FileManager
    private let rootURL: URL
    let homeDirectoryURL: URL
    private let captureURL: URL
    private let nodeShimDirectoryURL: URL

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        rootURL = fileManager.temporaryDirectory.appendingPathComponent("CodexHookRegression-\(UUID().uuidString)", isDirectory: true)
        homeDirectoryURL = rootURL.appendingPathComponent("home", isDirectory: true)
        captureURL = rootURL.appendingPathComponent("captured-sender-payload.json", isDirectory: false)
        nodeShimDirectoryURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeShimDirectoryURL, withIntermediateDirectories: true)
        try installNodeShim()
    }

    func cleanup() {
        try? fileManager.removeItem(at: rootURL)
    }

    func installCodexIntegration() throws {
        try CodexIntegrationInstaller(
            fileSystem: self,
            homeDirectoryURL: homeDirectoryURL
        ).install()
    }

    func installSenderCaptureScript() throws {
        try writeFile(at: senderURL, contents: """
        #!/bin/sh
        set -eu
        : "${PULSE_CAPTURE_PATH:?}"
        printf '%s' "$1" > "$PULSE_CAPTURE_PATH"
        """)
        try setExecutableBit(for: senderURL)
    }

    func normalizedSenderPayload(from rawPayload: Data) throws -> [String: Any] {
        try runHook(with: rawPayload)
        return try capturedSenderPayload()
    }

    func runHook(with payload: Data) throws {
        try clearCapturedPayload()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [hookScriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectoryURL.path
        environment["PULSE_CAPTURE_PATH"] = captureURL.path
        environment["PATH"] = nodeShimDirectoryURL.path
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(payload)
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "Hook failed: \(stderr)")

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("\"continue\":true"), "Hook did not continue: \(stdout)")
    }

    func capturedSenderPayload() throws -> [String: Any] {
        let data = try Data(contentsOf: captureURL)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    func didCaptureSenderPayload() -> Bool {
        fileManager.fileExists(atPath: captureURL.path)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func readFile(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func writeFile(at url: URL, contents: String) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func setExecutableBit(for url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func clearCapturedPayload() throws {
        if fileManager.fileExists(atPath: captureURL.path) {
            try fileManager.removeItem(at: captureURL)
        }
    }

    private var senderURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".pulse-agent-lights", isDirectory: true)
            .appendingPathComponent("pulse-agent-event-sender.sh")
    }

    private var hookScriptURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("pulse-agent-lights-hook.sh")
    }

    private func installNodeShim() throws {
        guard let nodeExecutableURL = Self.resolveNodeExecutableURL(fileManager: fileManager) else {
            throw NSError(
                domain: "CodexHookRegressionHarness",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to locate a node executable for the Codex hook harness"]
            )
        }

        let nodeShimURL = nodeShimDirectoryURL.appendingPathComponent("node")
        try writeFile(
            at: nodeShimURL,
            contents: """
            #!/bin/sh
            exec "\(nodeExecutableURL.path)" "$@"
            """
        )
        try setExecutableBit(for: nodeShimURL)
    }

    private static func resolveNodeExecutableURL(fileManager: FileManager) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node")
        ]

        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        let nvmRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == "node" {
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }
}

private final class InMemoryAgentIntegrationFileSystem: AgentIntegrationManagingFileSystem {
    enum Seed {
        case empty
        case codexInstalled
        case openCodeInstalled
        case bothInstalled
        case outdatedOpenCodeInstall
        case staleOpenCodePlugin
        case staleOpenCodeSender
        case staleCodexHook
        case staleCodexSender
        case userOwnedCodexHook
        case userOwnedCodexHooks
        case codexInstalledWithUserHooks
    }

    private var files: [URL: String]
    private var createdFiles: [URL: String] = [:]
    private(set) var overwrittenURLs: Set<URL> = []

    init(seed: Seed = .empty) {
        switch seed {
        case .empty:
            files = [:]
        case .codexInstalled:
            files = Self.makeCodexInstall()
        case .openCodeInstalled:
            files = Self.makeOpenCodeInstall()
        case .bothInstalled:
            files = Self.makeOpenCodeInstall().merging(Self.makeCodexInstall()) { _, new in new }
        case .outdatedOpenCodeInstall:
            files = Self.makeOpenCodeInstall(pluginVersion: "opencode-plugin-v0", senderVersion: "sender-v0")
        case .staleOpenCodePlugin:
            files = Self.makeOpenCodeInstall(pluginVersion: "opencode-plugin-v0")
        case .staleOpenCodeSender:
            files = Self.makeOpenCodeInstall(senderVersion: "sender-v0")
        case .staleCodexHook:
            files = Self.makeCodexInstall(hookVersion: "codex-hook-v0")
        case .staleCodexSender:
            files = Self.makeCodexInstall(senderVersion: "sender-v0")
        case .userOwnedCodexHook:
            let hookURL = URL(fileURLWithPath: "/Users/tester")
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("hooks", isDirectory: true)
                .appendingPathComponent("pulse-agent-lights-hook.sh")
            files = [hookURL: "#!/bin/sh\n# user-managed hook"]
        case .userOwnedCodexHooks:
            files = [
                Self.codexHooksURL: """
                {
                  "hooks": {
                    "Stop": [
                      {
                        "matcher": "*",
                        "hooks": [
                          {
                            "type": "command",
                            "command": "user-hook.sh"
                          }
                        ]
                      }
                    ]
                  }
                }
                """
            ]
        case .codexInstalledWithUserHooks:
            files = Self.makeCodexInstallWithUserHooks()
        }
    }

    func fileExists(at url: URL) -> Bool {
        files[url] != nil || createdFiles[url] != nil
    }

    func readFile(at url: URL) -> String? {
        files[url] ?? createdFiles[url]
    }

    func writeFile(at url: URL, contents: String) throws {
        if files[url] != nil || createdFiles[url] != nil {
            overwrittenURLs.insert(url)
        }
        if files[url] != nil {
            files[url] = contents
        } else {
            createdFiles[url] = contents
        }
    }

    func removeItem(at url: URL) throws {
        files.removeValue(forKey: url)
        createdFiles.removeValue(forKey: url)
    }

    func readCreatedFile(named name: String) -> String? {
        createdFiles.first { $0.key.lastPathComponent == name }?.value
    }

    var didOverwriteManagedOpenCodePlugin: Bool {
        overwrittenURLs.contains(Self.openCodePluginURL)
    }

    var sharedSenderStillExists: Bool {
        fileExists(at: Self.openCodeSenderURL)
    }

    var openCodePluginStillExists: Bool {
        fileExists(at: Self.openCodePluginURL)
    }

    var codexHookStillExists: Bool {
        fileExists(at: Self.codexHookURL)
    }

    var userOwnedCodexHookStillExists: Bool {
        fileExists(at: Self.codexHookURL)
    }

    var userOwnedCodexHooksStillExists: Bool {
        fileExists(at: Self.codexHooksURL)
    }

    private static let testerHomeURL = URL(fileURLWithPath: "/Users/tester")

    static let openCodePluginURL = testerHomeURL
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
        .appendingPathComponent("plugins", isDirectory: true)
        .appendingPathComponent("pulse-agent-lights.ts")

    private static let openCodeSenderURL = testerHomeURL
        .appendingPathComponent(".pulse-agent-lights", isDirectory: true)
        .appendingPathComponent("pulse-agent-event-sender.sh")

    private static let codexHookURL = testerHomeURL
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("hooks", isDirectory: true)
        .appendingPathComponent("pulse-agent-lights-hook.sh")

    static let codexHooksURL = testerHomeURL
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("hooks.json")

    private static func makeOpenCodeInstall(
        pluginVersion: String = "opencode-plugin-v1",
        senderVersion: String = "sender-v1"
    ) -> [URL: String] {
        [
            openCodeSenderURL: """
            #!/bin/sh
            # PULSE_AGENT_SENDER_VERSION=\(senderVersion)
            # pulse-agent-event-sender
            """,
            openCodePluginURL: """
            // pulse-agent-lights
            // pulse-agent-event-sender
            // PULSE_OPENCODE_PLUGIN_VERSION=\(pluginVersion)
            """
        ]
    }

    private static func makeCodexInstall(
        hookVersion: String = "codex-hook-v3",
        senderVersion: String = "sender-v1"
    ) -> [URL: String] {
        [
            openCodeSenderURL: """
            #!/bin/sh
            # PULSE_AGENT_SENDER_VERSION=\(senderVersion)
            # pulse-agent-event-sender
            """,
            codexHookURL: """
            #!/bin/sh
            # PULSE_CODEX_HOOK_VERSION=\(hookVersion)
            # codex
            # pulse-agent-event-sender
            # hook_event_name
            """,
            codexHooksURL: """
            {
              "hooks": {
                "UserPromptSubmit": [
                  {
                    "matcher": "*",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/Users/tester/.codex/hooks/pulse-agent-lights-hook.sh"
                      }
                    ]
                  }
                ],
                "SubagentStart": [
                  {
                    "matcher": "*",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/Users/tester/.codex/hooks/pulse-agent-lights-hook.sh"
                      }
                    ]
                  }
                ],
                "SubagentStop": [
                  {
                    "matcher": "*",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/Users/tester/.codex/hooks/pulse-agent-lights-hook.sh"
                      }
                    ]
                  }
                ],
                "Stop": [
                  {
                    "matcher": "*",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/Users/tester/.codex/hooks/pulse-agent-lights-hook.sh"
                      }
                    ]
                  }
                ]
              }
            }
            """
        ]
    }

    private static func makeCodexInstallWithUserHooks(
        hookVersion: String = "codex-hook-v3",
        senderVersion: String = "sender-v1"
    ) -> [URL: String] {
        var install = makeCodexInstall(hookVersion: hookVersion, senderVersion: senderVersion)
        install[codexHooksURL] = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/Users/tester/.codex/hooks/pulse-agent-lights-hook.sh"
                  },
                  {
                    "type": "command",
                    "command": "user-hook.sh"
                  }
                ]
              }
            ]
          }
        }
        """
        return install
    }
}
