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
        function firstNonEmptyString(...values) {
          for (const value of values) {
            if (typeof value === "string" && value.length > 0) {
              return value;
            }
          }

          return "";
        }

        function readNestedParentThreadID(sourceValue) {
          if (typeof sourceValue !== "object" || sourceValue === null) {
            return "";
          }

          return firstNonEmptyString(
            sourceValue.subagent?.thread_spawn?.parent_thread_id,
            sourceValue.subagent?.thread_spawn?.parentThreadId,
            sourceValue.subagent?.parent_thread_id,
            sourceValue.subagent?.parentThreadId,
            sourceValue.thread_spawn?.parent_thread_id,
            sourceValue.thread_spawn?.parentThreadId,
            sourceValue.parent_thread_id,
            sourceValue.parentThreadId
          );
        }

        function normalizeSessionID(payload) {
          return firstNonEmptyString(
            payload.session_id,
            payload.sessionID,
            payload.sessionId,
            payload.thread_id,
            payload.threadId,
            payload.threadID,
            payload.conversation_id,
            payload.conversationId,
            payload.transcript_path,
            payload.transcriptPath
          );
        }

        function normalizeParentSessionID(payload) {
          return firstNonEmptyString(
            payload.parent_thread_id,
            payload.parentThreadId,
            payload.parent_session_id,
            payload.parentSessionID,
            payload.parentSessionId,
            readNestedParentThreadID(payload.source)
          );
        }

        function normalizeThreadSource(payload) {
          return firstNonEmptyString(
            payload.thread_source,
            payload.threadSource,
            payload.source?.thread_source,
            payload.source?.threadSource
          );
        }

        function hasNestedSubagentSource(sourceValue) {
          if (typeof sourceValue !== "object" || sourceValue === null) {
            return false;
          }

          return firstNonEmptyString(
            sourceValue.subagent?.thread_spawn?.parent_thread_id,
            sourceValue.subagent?.thread_spawn?.parentThreadId,
            sourceValue.subagent?.parent_thread_id,
            sourceValue.subagent?.parentThreadId
          ).length > 0;
        }

        function isSubagentEvent(payload, eventNameValue, normalizedParentSessionID) {
          if (eventNameValue.startsWith("Subagent")) {
            return true;
          }

          const threadSource = normalizeThreadSource(payload);
          const hasThreadSourceMetadata = threadSource === "subagent" || hasNestedSubagentSource(payload.source);

          if (hasThreadSourceMetadata) {
            return normalizedParentSessionID.length > 0;
          }

          if (normalizedParentSessionID.length > 0) {
            return true;
          }

          return false;
        }

        const sessionID = normalizeSessionID(payload);
        const parentSessionID = normalizeParentSessionID(payload);
        const projectPath = String(payload.cwd ?? payload.directory ?? payload.project_path ?? payload.projectPath ?? process.cwd());
        const title = String(payload.title ?? payload.session_title ?? payload.sessionTitle ?? "");
        const threadSource = normalizeThreadSource(payload);
        const isSubagent = isSubagentEvent(payload, eventName, parentSessionID);
        const kind = eventName === "Stop" || eventName === "SubagentStop" ? "session.idle" :
          eventName === "SessionStart" ? "session.started" : "session.working";
        const sender = "\(senderURL.path)";
        const normalizedTitle = title.length > 0 ? title : (projectPath.split("/").filter(Boolean).pop() || "Codex Session");

        if (eventName === "SessionStart" && source === "startup") {
          process.stdout.write(JSON.stringify({ continue: true }) + "\\n");
          process.exit(0);
        }

        if (threadSource === "system") {
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
