import Combine
import Foundation

protocol AgentIntegrationFileSystem {
    func fileExists(at url: URL) -> Bool
    func readFile(at url: URL) -> String?
}

protocol AgentIntegrationManagingFileSystem: AgentIntegrationInstallerFileSystem {
    func removeItem(at url: URL) throws
}

final class AgentIntegrationManager: ObservableObject {
    private let fileSystem: any AgentIntegrationManagingFileSystem
    private let homeDirectoryURL: URL
    private var installFailures: [AgentStatusAgent: String] = [:]

    convenience init() {
        self.init(
            fileSystem: LocalAgentIntegrationFileSystem(),
            homeDirectoryURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
    }

    init(fileSystem: any AgentIntegrationManagingFileSystem, homeDirectoryURL: URL) {
        self.fileSystem = fileSystem
        self.homeDirectoryURL = homeDirectoryURL
    }

    func status(for agent: AgentStatusAgent) -> AgentIntegrationStatus {
        if let failure = installFailures[agent] {
            return failedStatus(for: agent, message: failure)
        }

        if agent == .codex {
            return codexStatus()
        }

        let layout = layout(for: agent)

        guard fileSystem.fileExists(at: layout.primaryURL) else {
            return notInstalledStatus(for: agent)
        }

        guard primaryFileHasManagedVersion(for: layout) else {
            return outdatedStatus(for: agent)
        }

        return installedStatus(for: agent)
    }

    func performPrimaryAction(for agent: AgentStatusAgent) throws {
        do {
            switch status(for: agent).state {
            case .notInstalled:
                try install(agent)
            case .installed, .installedNeedsRestart, .installedNeedsActivation, .outdated, .installFailed:
                try reinstall(agent)
            }

            installFailures[agent] = nil
            objectWillChange.send()
        } catch {
            installFailures[agent] = error.localizedDescription
            objectWillChange.send()
            throw error
        }
    }

    func performSecondaryAction(_ title: String, for agent: AgentStatusAgent) throws {
        switch title {
        case "Recheck":
            installFailures[agent] = nil
            objectWillChange.send()
        case "Uninstall":
            do {
                try uninstall(agent)
                installFailures[agent] = nil
                objectWillChange.send()
            } catch {
                installFailures[agent] = error.localizedDescription
                objectWillChange.send()
                throw error
            }
        default:
            break
        }
    }

    func reinstall(_ agent: AgentStatusAgent) throws {
        try uninstall(agent)
        try install(agent)
    }

    func uninstall(_ agent: AgentStatusAgent) throws {
        if agent == .codex {
            try uninstallCodex()
            return
        }

        let layout = layout(for: agent)
        let sharedSenderURL = senderURL(for: agent)

        for file in layout.files where file.url != sharedSenderURL && isPulseManaged(file.url) {
            try fileSystem.removeItem(at: file.url)
        }

        if shouldRemoveSharedSender(afterUninstalling: agent), isPulseManaged(sharedSenderURL) {
            try fileSystem.removeItem(at: sharedSenderURL)
        }
    }

    private func install(_ agent: AgentStatusAgent) throws {
        switch agent {
        case .openCode:
            try OpenCodeIntegrationInstaller(
                fileSystem: fileSystem,
                homeDirectoryURL: homeDirectoryURL
            ).install()
        case .codex:
            try CodexIntegrationInstaller(
                fileSystem: fileSystem,
                homeDirectoryURL: homeDirectoryURL
            ).install()
        }
    }

    private func codexStatus() -> AgentIntegrationStatus {
        let hookScriptExists = fileSystem.fileExists(at: codexHookURL)
        let hookScriptManaged = isPulseManaged(codexHookURL)
        let hooksContainPulseHook = codexHooksContainPulseHook()
        let hasAnyPulseFootprint = hookScriptExists || hooksContainPulseHook

        if hookScriptManaged && hooksContainPulseHook {
            return installedStatus(for: .codex)
        }

        if hasAnyPulseFootprint {
            return outdatedStatus(for: .codex)
        }

        return notInstalledStatus(for: .codex)
    }

    private func primaryFileHasManagedVersion(for layout: AgentIntegrationLayout) -> Bool {
        guard let contents = fileSystem.readFile(at: layout.primaryURL) else {
            return false
        }

        return contents.contains(managedVersionMarker)
    }

    private func isPulseManaged(_ url: URL) -> Bool {
        guard let contents = fileSystem.readFile(at: url) else {
            return false
        }

        return contents.contains(managedVersionMarker)
    }

    private func shouldRemoveSharedSender(afterUninstalling agent: AgentStatusAgent) -> Bool {
        !isManagedInstalled(agent: otherAgent(for: agent))
    }

    private func isManagedInstalled(agent: AgentStatusAgent) -> Bool {
        if agent == .codex {
            return isPulseManaged(codexHookURL) && codexHooksContainPulseHook()
        }

        let layout = layout(for: agent)
        return fileSystem.fileExists(at: layout.primaryURL) && primaryFileHasManagedVersion(for: layout)
    }

    private func uninstallCodex() throws {
        if isPulseManaged(codexHookURL) {
            try fileSystem.removeItem(at: codexHookURL)
        }

        if let hooksJSON = fileSystem.readFile(at: codexHooksURL) {
            let manifest = try CodexHooksManifest(existingJSON: hooksJSON)
            let updatedManifest = manifest.removingPulseHooks(command: codexHookURL.path)

            if updatedManifest.isEmpty {
                try fileSystem.removeItem(at: codexHooksURL)
            } else {
                try fileSystem.writeFile(at: codexHooksURL, contents: try updatedManifest.render())
            }
        }

        if shouldRemoveSharedSender(afterUninstalling: .codex), isPulseManaged(codexSenderURL) {
            try fileSystem.removeItem(at: codexSenderURL)
        }
    }

    private func codexHooksContainPulseHook() -> Bool {
        guard let contents = fileSystem.readFile(at: codexHooksURL) else {
            return false
        }

        guard let manifest = try? CodexHooksManifest(existingJSON: contents) else {
            return contents.contains(codexHookURL.path)
        }

        return manifest.containsPulseHook(command: codexHookURL.path)
    }

    private func otherAgent(for agent: AgentStatusAgent) -> AgentStatusAgent {
        switch agent {
        case .openCode:
            return .codex
        case .codex:
            return .openCode
        }
    }

    private func notInstalledStatus(for agent: AgentStatusAgent) -> AgentIntegrationStatus {
        AgentIntegrationStatus(
            agent: agent,
            state: .notInstalled,
            primaryActionTitle: agent == .openCode ? "Install Plugin" : "Install Hook",
            secondaryActions: [],
            guidance: []
        )
    }

    private func outdatedStatus(for agent: AgentStatusAgent) -> AgentIntegrationStatus {
        AgentIntegrationStatus(
            agent: agent,
            state: .outdated,
            primaryActionTitle: "Reinstall",
            secondaryActions: ["Recheck", "Uninstall"],
            guidance: []
        )
    }

    private func failedStatus(for agent: AgentStatusAgent, message: String) -> AgentIntegrationStatus {
        AgentIntegrationStatus(
            agent: agent,
            state: .installFailed(message),
            primaryActionTitle: agent == .openCode ? "Install Plugin" : "Install Hook",
            secondaryActions: ["Recheck"],
            guidance: [message]
        )
    }

    private func installedStatus(for agent: AgentStatusAgent) -> AgentIntegrationStatus {
        switch agent {
        case .openCode:
            return AgentIntegrationStatus(
                agent: .openCode,
                state: .installedNeedsRestart,
                primaryActionTitle: "Reinstall",
                secondaryActions: ["Recheck", "Uninstall"],
                guidance: ["Restart OpenCode so the Pulse plugin is loaded."]
            )
        case .codex:
            return AgentIntegrationStatus(
                agent: .codex,
                state: .installedNeedsActivation,
                primaryActionTitle: "Reinstall",
                secondaryActions: ["Recheck", "Uninstall"],
                guidance: [
                    "Open any Codex session.",
                    "Open the Hooks view in Codex.",
                    "Review the Pulse hook.",
                    "Trust it so Codex can run it."
                ]
            )
        }
    }

    private func layout(for agent: AgentStatusAgent) -> AgentIntegrationLayout {
        switch agent {
        case .openCode:
            return AgentIntegrationLayout(
                primaryURL: openCodePluginURL,
                files: [
                    ManagedFile(
                        url: openCodeSenderURL,
                        requiresManagedVersion: true
                    ),
                    ManagedFile(
                        url: openCodePluginURL,
                        requiresManagedVersion: true
                    )
                ]
            )
        case .codex:
            return AgentIntegrationLayout(
                primaryURL: codexHooksURL,
                files: [
                    ManagedFile(
                        url: codexSenderURL,
                        requiresManagedVersion: true
                    ),
                    ManagedFile(
                        url: codexHookURL,
                        requiresManagedVersion: true
                    ),
                    ManagedFile(
                        url: codexHooksURL,
                        requiresManagedVersion: true
                    )
                ]
            )
        }
    }

    private var openCodeSenderURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".pulse-agent-lights", isDirectory: true)
            .appendingPathComponent("pulse-agent-event-sender.sh")
    }

    private var openCodePluginURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("pulse-agent-lights.ts")
    }

    private var codexSenderURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".pulse-agent-lights", isDirectory: true)
            .appendingPathComponent("pulse-agent-event-sender.sh")
    }

    private var codexHookURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("pulse-agent-lights-hook.sh")
    }

    private var codexHooksURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    private var managedVersionMarker: String {
        "PULSE_MANAGED_VERSION=\(PulseAgentEventSenderTemplate.managedVersion)"
    }

    private func senderURL(for agent: AgentStatusAgent) -> URL {
        switch agent {
        case .openCode:
            return openCodeSenderURL
        case .codex:
            return codexSenderURL
        }
    }
}

private struct AgentIntegrationLayout {
    let primaryURL: URL
    let files: [ManagedFile]
}

private struct ManagedFile {
    let url: URL
    let requiresManagedVersion: Bool
}

private final class LocalAgentIntegrationFileSystem: AgentIntegrationManagingFileSystem {
    private let fileManager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func readFile(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func writeFile(at url: URL, contents: String) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)

        if url.pathExtension == "sh" {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func removeItem(at url: URL) throws {
        guard fileExists(at: url) else {
            return
        }

        try fileManager.removeItem(at: url)
    }
}
