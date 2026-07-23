import Foundation

protocol AgentIntegrationWritableFileSystem {
    func writeFile(at url: URL, contents: String) throws
}

typealias AgentIntegrationInstallerFileSystem = AgentIntegrationFileSystem & AgentIntegrationWritableFileSystem

enum PulseAgentEventSenderTemplate {
    static let senderVersion = "sender-v1"
    static let codexHookVersion = "codex-hook-v3"
    static let openCodePluginVersion = "opencode-plugin-v1"

    static func script(listenerPort: Int) -> String {
        """
        #!/bin/sh
        # PULSE_AGENT_SENDER_VERSION=\(senderVersion)
        # pulse-agent-event-sender
        debug_enabled_file="$HOME/.pulse-agent-lights/debug-enabled"
        sender_log="$HOME/.pulse-agent-lights/logs/pulse-agent-sender.log"
        if [ -f "$debug_enabled_file" ]; then
            mkdir -p "$HOME/.pulse-agent-lights/logs" 2>/dev/null || true
        fi
        raw_payload="${1:-}"
        if [ -n "$raw_payload" ]; then
            if [ -f "$debug_enabled_file" ]; then
                printf '[%s] raw_payload %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$raw_payload" >> "$sender_log" 2>/dev/null || true
            fi
            case "$raw_payload" in
                {*)
                    node -e '
                    const net = require("net");
                    const payload = process.argv[1];
                    const client = net.createConnection({ host: "127.0.0.1", port: \(listenerPort) }, () => {
                      client.end(payload + "\\n");
                    });
                    client.on("error", () => process.exit(0));
                    ' "$raw_payload"
                    exit 0
                    ;;
            esac
        fi

        event_kind="${1:-session.idle}"
        agent="${2:-opencode}"
        session_id="${3:-legacy-$$-$(date +%s)}"
        project_path="${4:-$PWD}"
        title="${5:-$(basename "$project_path")}"
        message="${6:-}"
        if [ -f "$debug_enabled_file" ]; then
            printf '[%s] positional_args kind=%s agent=%s session_id=%s project_path=%s title=%s message=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event_kind" "$agent" "$session_id" "$project_path" "$title" "$message" >> "$sender_log" 2>/dev/null || true
        fi
        node -e '
        const net = require("net");
        const [kind, agent, sessionID, projectPath, title, message] = process.argv.slice(1);
        const payload = JSON.stringify({
          agent,
          sessionID,
          projectPath,
          title,
          timestamp: new Date().toISOString(),
          kind,
          ...(message ? { message } : {}),
        });
        const client = net.createConnection({ host: "127.0.0.1", port: \(listenerPort) }, () => {
          client.end(payload + "\\n");
        });
        client.on("error", () => process.exit(0));
        ' "$event_kind" "$agent" "$session_id" "$project_path" "$title" "$message"
        """
    }
}
