import Foundation

struct CodexIntegrationInstaller {
    private let fileSystem: any AgentIntegrationInstallerFileSystem
    private let homeDirectoryURL: URL
    private let listenerPort: Int

    init(
        fileSystem: any AgentIntegrationInstallerFileSystem,
        homeDirectoryURL: URL,
        listenerPort: Int = 45821
    ) {
        self.fileSystem = fileSystem
        self.homeDirectoryURL = homeDirectoryURL
        self.listenerPort = listenerPort
    }

    func install() throws {
        try fileSystem.writeFile(at: senderURL, contents: PulseAgentEventSenderTemplate.script(listenerPort: listenerPort))
        try fileSystem.writeFile(at: hookScriptURL, contents: hookScriptSource())
        try fileSystem.writeFile(at: hooksConfigURL, contents: mergedHooksConfigSource())
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

    private var hooksConfigURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    private func hookScriptSource() -> String {
        """
        #!/bin/sh
        # PULSE_MANAGED_VERSION=\(PulseAgentEventSenderTemplate.managedVersion)
        # codex
        # pulse-agent-event-sender
        # hook_event_name
        /usr/bin/env node -e '
        const { readFileSync } = require("node:fs");
        const { spawnSync } = require("node:child_process");
        const payload = JSON.parse(readFileSync(0, "utf8") || "{}");
        const eventName = String(payload.hook_event_name ?? payload.event ?? payload.hookEventName ?? "");
        const source = String(payload.source ?? "");
        const sessionID = String(
          payload.transcript_path ??
          payload.transcriptPath ??
          payload.session_id ??
          payload.sessionID ??
          payload.sessionId ??
          payload.conversation_id ??
          payload.conversationId ??
          payload.thread_id ??
          payload.threadId ??
          payload.turn_id ??
          payload.turnId ??
          ""
        );
        const parentSessionID = String(
          payload.parent_session_id ??
          payload.parentSessionID ??
          payload.parentSessionId ??
          payload.parent_id ??
          payload.parentId ??
          payload.parent ??
          ""
        );
        const projectPath = String(payload.cwd ?? payload.directory ?? payload.project_path ?? payload.projectPath ?? process.cwd());
        const title = String(payload.title ?? payload.session_title ?? payload.sessionTitle ?? "");
        const isSubagent = eventName.startsWith("Subagent");
        const kind = eventName === "Stop" || eventName === "SubagentStop" ? "session.idle" : "session.working";
        const sender = "\(senderURL.path)";
        const normalizedTitle = title.length > 0 ? title : (projectPath.split("/").filter(Boolean).pop() || "Codex Session");

        if (eventName === "SessionStart" && source === "startup") {
          process.stdout.write(JSON.stringify({ continue: true }) + "\\n");
          process.exit(0);
        }

        const normalizedPayload = {
          agent: "codex",
          sessionID: sessionID || `codex-${Date.now()}`,
          projectPath,
          title: normalizedTitle,
          timestamp: new Date().toISOString(),
          kind,
          ...(parentSessionID.length > 0 ? { parentSessionID } : {}),
          ...(isSubagent ? { isSubagent: true } : {}),
        };

        spawnSync(sender, [JSON.stringify(normalizedPayload)], { stdio: "ignore" });
        process.stdout.write(JSON.stringify({ continue: true }) + "\\n");
        '
        """
    }

    private func mergedHooksConfigSource() throws -> String {
        let manifest = try CodexHooksManifest(existingJSON: fileSystem.readFile(at: hooksConfigURL))
        return try manifest.mergingPulseHooks(command: hookScriptURL.path).render()
    }
}
