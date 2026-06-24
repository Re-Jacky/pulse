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
        XCTAssertTrue(plugin.contains("PULSE_MANAGED_VERSION"))
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
        XCTAssertTrue(hook.contains("PULSE_MANAGED_VERSION"))
        XCTAssertTrue(hook.contains("hook_event_name"))
        XCTAssertTrue(hook.contains("parentSessionID"))
        XCTAssertTrue(hook.contains("isSubagent"))
        XCTAssertTrue(hook.contains("payload.transcript_path"))
        XCTAssertTrue(hook.contains("payload.thread_id"))
        XCTAssertTrue(hook.contains("payload.turn_id"))
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
        XCTAssertTrue(plugin.contains(PulseAgentEventSenderTemplate.managedVersion))
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

private final class InMemoryAgentIntegrationFileSystem: AgentIntegrationManagingFileSystem {
    enum Seed {
        case empty
        case codexInstalled
        case openCodeInstalled
        case bothInstalled
        case outdatedOpenCodeInstall
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
            files = Self.makeOpenCodeInstall(managedVersion: "pulse-agent-lights-v0")
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

    private static func makeOpenCodeInstall(managedVersion: String = PulseAgentEventSenderTemplate.managedVersion) -> [URL: String] {
        [
            openCodeSenderURL: """
            #!/bin/sh
            # PULSE_MANAGED_VERSION=\(managedVersion)
            # pulse-agent-event-sender
            """,
            openCodePluginURL: """
            // pulse-agent-lights
            // pulse-agent-event-sender
            // PULSE_MANAGED_VERSION=\(managedVersion)
            """
        ]
    }

    private static func makeCodexInstall(managedVersion: String = PulseAgentEventSenderTemplate.managedVersion) -> [URL: String] {
        [
            openCodeSenderURL: """
            #!/bin/sh
            # PULSE_MANAGED_VERSION=\(managedVersion)
            # pulse-agent-event-sender
            """,
            codexHookURL: """
            #!/bin/sh
            # PULSE_MANAGED_VERSION=\(managedVersion)
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

    private static func makeCodexInstallWithUserHooks(managedVersion: String = PulseAgentEventSenderTemplate.managedVersion) -> [URL: String] {
        var install = makeCodexInstall(managedVersion: managedVersion)
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
