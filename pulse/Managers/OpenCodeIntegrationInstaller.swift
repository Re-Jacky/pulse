import Foundation

struct OpenCodeIntegrationInstaller {
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
        try fileSystem.writeFile(at: pluginURL, contents: pluginSource())
    }

    private var senderURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".pulse-agent-lights", isDirectory: true)
            .appendingPathComponent("pulse-agent-event-sender.sh")
    }

    private var pluginURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("pulse-agent-lights.ts")
    }

    private func pluginSource() -> String {
        """
        // PULSE_MANAGED_VERSION=\(PulseAgentEventSenderTemplate.managedVersion)
        // pulse-agent-lights
        // pulse-agent-event-sender
        // opencode
        import { spawn } from "node:child_process";
        import { appendFileSync, existsSync, mkdirSync } from "node:fs";
        import { homedir } from "node:os";
        import { basename } from "node:path";

        const sender = "\(senderURL.path)";
        const agent = "opencode";
        const sessionInfoByID = new Map();
        const debugEnabledPath = `${homedir()}/.pulse-agent-lights/debug-enabled`;
        const debugLogPath = `${homedir()}/.pulse-agent-lights/logs/opencode-plugin.log`;

        function defaultTitle(projectPath) {
          return basename(projectPath) || "OpenCode Session";
        }

        function writeDebugLog(message, details = undefined) {
          if (existsSync(debugEnabledPath) === false) {
            return;
          }

          try {
            mkdirSync(`${homedir()}/.pulse-agent-lights/logs`, { recursive: true });
            const payload = details === undefined ? "" : ` ${JSON.stringify(details)}`;
            appendFileSync(debugLogPath, `[${new Date().toISOString()}] ${message}${payload}\\n`);
          } catch {}
        }

        function readSessionID(properties) {
          if (typeof properties?.sessionID === "string" && properties.sessionID.length > 0) {
            return properties.sessionID;
          }

          if (typeof properties?.id === "string" && properties.id.length > 0) {
            return properties.id;
          }

          if (typeof properties?.info?.id === "string" && properties.info.id.length > 0) {
            return properties.info.id;
          }

          return "";
        }

        function rememberSessionInfo(sessionID, info) {
          if (typeof sessionID !== "string" || sessionID.length === 0) {
            return;
          }

          const existing = sessionInfoByID.get(sessionID) ?? {};
          sessionInfoByID.set(sessionID, {
            parentSessionID: info.parentSessionID ?? existing.parentSessionID ?? "",
            projectPath: info.projectPath ?? existing.projectPath ?? "",
            title: info.title ?? existing.title ?? "",
          });
        }

        function readParentSessionID(properties, sessionID) {
          if (typeof properties?.parentID === "string" && properties.parentID.length > 0) {
            return properties.parentID;
          }

          if (typeof properties?.parentId === "string" && properties.parentId.length > 0) {
            return properties.parentId;
          }

          if (typeof properties?.info?.parentID === "string" && properties.info.parentID.length > 0) {
            return properties.info.parentID;
          }

          if (typeof properties?.info?.parentId === "string" && properties.info.parentId.length > 0) {
            return properties.info.parentId;
          }

          const cached = sessionInfoByID.get(sessionID);
          if (typeof cached?.parentSessionID === "string" && cached.parentSessionID.length > 0) {
            return cached.parentSessionID;
          }

          return "";
        }

        function normalizeParentSessionID(parentSessionID) {
          if (typeof parentSessionID !== "string") {
            return "";
          }

          return parentSessionID.startsWith("ses_") ? parentSessionID : "";
        }

        async function loadSessionInfo(client, sessionID) {
          if (typeof sessionID !== "string" || sessionID.length === 0) {
            return {};
          }

          try {
            const response = await client.session.get({
              path: { id: sessionID },
            });
            const session = response?.data ?? response;
            if (session && typeof session === "object") {
              return {
                parentSessionID: typeof session.parentID === "string" ? session.parentID : "",
                projectPath: typeof session.directory === "string" ? session.directory : "",
                title: typeof session.title === "string" ? session.title : "",
              };
            }
          } catch {}

          return {};
        }

        function readProjectPath(properties, fallbackProjectPath, sessionID) {
          if (typeof properties?.directory === "string" && properties.directory.length > 0) {
            return properties.directory;
          }

          if (typeof properties?.info?.directory === "string" && properties.info.directory.length > 0) {
            return properties.info.directory;
          }

          const cached = sessionInfoByID.get(sessionID);
          if (typeof cached?.projectPath === "string" && cached.projectPath.length > 0) {
            return cached.projectPath;
          }

          return fallbackProjectPath;
        }

        function readTitle(properties, sessionID, projectPath) {
          if (typeof properties?.title === "string" && properties.title.length > 0) {
            return properties.title;
          }

          if (typeof properties?.info?.title === "string" && properties.info.title.length > 0) {
            return properties.info.title;
          }

          const cached = sessionInfoByID.get(sessionID);
          if (typeof cached?.title === "string" && cached.title.length > 0) {
            return cached.title;
          }

          return defaultTitle(projectPath);
        }

        async function sendToPulse(payload) {
          await new Promise((resolve) => {
            const child = spawn(sender, [JSON.stringify(payload)], { stdio: "ignore" });
            child.on("error", () => resolve(undefined));
            child.on("exit", () => resolve(undefined));
          });
        }

        export default async function pulseAgentLightsPlugin(input) {
          const fallbackProjectPath = input.directory;

          return {
            event: async ({ event }) => {
              const properties = event.properties ?? {};
              const sessionID = readSessionID(properties);
              const sessionInfo = await loadSessionInfo(input.client, sessionID);
              const projectPath = readProjectPath({ ...properties, directory: sessionInfo.projectPath }, fallbackProjectPath, sessionID);
              const parentSessionID = readParentSessionID({ ...properties, parentID: sessionInfo.parentSessionID }, sessionID);
              const normalizedParentSessionID = normalizeParentSessionID(parentSessionID);
              const isSubagent = normalizedParentSessionID.length > 0;
              const title = readTitle({ ...properties, title: sessionInfo.title }, sessionID, projectPath);

              rememberSessionInfo(sessionID, {
                parentSessionID: parentSessionID || undefined,
                projectPath,
                title,
              });

              writeDebugLog("received event", {
                type: event.type,
                sessionID,
                parentSessionID,
                normalizedParentSessionID,
                isSubagent,
                title,
                projectPath,
                propertyKeys: Object.keys(properties),
                infoKeys: typeof properties?.info === "object" && properties.info !== null ? Object.keys(properties.info) : [],
              });

              let kind = null;
              let message;

              switch (event.type) {
              case "session.created":
                kind = "session.working";
                break;
              case "session.updated":
              case "message.updated":
                writeDebugLog("ignored metadata-only event", {
                  type: event.type,
                  sessionID,
                  parentSessionID,
                  normalizedParentSessionID,
                });
                return;
              case "session.status":
                kind = properties?.status?.type === "idle" ? "session.idle" : "session.working";
                if (properties?.status?.type === "retry" && typeof properties.status.message === "string") {
                  message = properties.status.message;
                }
                break;
              case "session.idle":
                kind = "session.idle";
                break;
              case "session.error":
                kind = "session.error";
                if (typeof properties?.error?.data?.message === "string") {
                  message = properties.error.data.message;
                }
                break;
              case "session.deleted":
                kind = "session.closed";
                break;
              default:
                writeDebugLog("ignored unsupported event", { type: event.type });
                return;
              }

              if (sessionID.length === 0 || kind === null) {
                writeDebugLog("skipped event", {
                  type: event.type,
                  sessionID,
                  kind,
                  parentSessionID,
                  title,
                });
                return;
              }

              const resolvedTitle = readTitle({ ...properties, title: sessionInfo.title }, sessionID, projectPath);

              writeDebugLog("sending payload", {
                type: event.type,
                sessionID,
                parentSessionID: normalizedParentSessionID,
                isSubagent,
                projectPath,
                resolvedTitle,
                kind,
                message,
              });

              await sendToPulse({
                agent,
                sessionID,
                projectPath,
                title: resolvedTitle,
                timestamp: new Date().toISOString(),
                kind,
                parentSessionID: normalizedParentSessionID || undefined,
                isSubagent,
                ...(message ? { message } : {}),
              });

              if (event.type === "session.deleted") {
                sessionInfoByID.delete(sessionID);
              }
            },
          };
        }
        """
    }
}
