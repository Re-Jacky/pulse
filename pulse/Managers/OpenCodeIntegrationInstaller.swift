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
        // PULSE_OPENCODE_PLUGIN_VERSION=\(PulseAgentEventSenderTemplate.openCodePluginVersion)
        // pulse-agent-lights
        // pulse-agent-event-sender
        // opencode
        //
        // Supports both plugin APIs from one local file:
        //   * OpenCode V2 invokes `setup(ctx)` and streams events via `ctx.event.subscribe`.
        //   * OpenCode V1 (>= 1.18.29) invokes `server(input)` and returns an `event` hook.
        // It intentionally does not import "@opencode/plugin": a local plugin file cannot
        // resolve that package, and V2 only requires `default.{ id, setup }`.
        import { spawn } from "node:child_process";
        import { appendFileSync, existsSync, mkdirSync } from "node:fs";
        import { homedir } from "node:os";
        import { basename } from "node:path";

        const sender = "\(senderURL.path)";
        const agent = "opencode";
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
            appendFileSync(debugLogPath, `[${new Date().toISOString()}] ${message}${payload}\n`);
          } catch {}
        }

        async function sendToPulse(payload) {
          await new Promise((resolve) => {
            const child = spawn(sender, [JSON.stringify(payload)], { stdio: "ignore" });
            child.on("error", () => resolve(undefined));
            child.on("exit", () => resolve(undefined));
          });
        }

        function normalizeParentSessionID(parentSessionID) {
          if (typeof parentSessionID !== "string") {
            return "";
          }

          return parentSessionID.startsWith("ses_") ? parentSessionID : "";
        }

        // Maps both OpenCode V2 lifecycle events and legacy V1 event names onto Pulse kinds.
        function resolveKind(eventType, properties = undefined) {
          const toolName = properties?.toolName ?? properties?.tool ?? properties?.name ?? properties?.part?.name ?? properties?.part?.tool;
          const isQuestionToolCall = toolName === "question" || Array.isArray(properties?.input?.questions);

          switch (eventType) {
          case "session.created":
            return "session.working";
          case "session.status":
            return properties?.status?.type === "idle" ? "session.idle" : "session.working";
          case "session.inbox.enqueued":
          case "session.inbox.delivered":
          case "session.execution.started":
          case "session.step.started":
            return "session.working";
          case "session.tool.called":
            return isQuestionToolCall ? "session.idle" : "session.working";
          case "session.tool.success":
            return "session.working";
          case "session.execution.succeeded":
          case "session.execution.interrupted":
          case "session.idle":
            return "session.idle";
          case "session.execution.failed":
          case "session.error":
            return "session.error";
          case "session.closed":
          case "session.deleted":
            return "session.closed";
          default:
            return null;
          }
        }

        // OpenCode V2 entrypoint.
        async function setup(ctx) {
          const fallbackProjectPath = ctx?.location?.directory ?? process.cwd();
          const sessionInfoByID = new Map();
          const lastKindBySession = new Map();

          function readSessionID(event) {
            const data = event?.data ?? {};
            if (typeof data.sessionID === "string" && data.sessionID.length > 0) {
              return data.sessionID;
            }

            if (typeof data.id === "string" && data.id.length > 0) {
              return data.id;
            }

            return "";
          }

          function readInlineProjectPath(event) {
            if (typeof event?.location?.directory === "string" && event.location.directory.length > 0) {
              return event.location.directory;
            }

            if (typeof event?.data?.location?.directory === "string" && event.data.location.directory.length > 0) {
              return event.data.location.directory;
            }

            return "";
          }

          function readInlineTitle(event) {
            if (typeof event?.data?.title === "string" && event.data.title.length > 0) {
              return event.data.title;
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

          async function loadSessionInfo(sessionID) {
            if (typeof sessionID !== "string" || sessionID.length === 0) {
              return {};
            }

            try {
              const session = await ctx.session.get({ sessionID });
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

          async function handleEvent(event) {
            const type = typeof event?.type === "string" ? event.type : "";
            const sessionID = readSessionID(event);

            if (type === "session.updated" || type === "message.updated") {
              writeDebugLog("ignored metadata-only event", { type, sessionID });
              return;
            }

            if (sessionID.length === 0) {
              writeDebugLog("skipped event without session id", { type });
              return;
            }

            const cachedInfo = sessionInfoByID.get(sessionID);
            const shouldLoadInfo = cachedInfo === undefined || type === "session.created" || type === "session.renamed";
            const sessionInfo = shouldLoadInfo ? await loadSessionInfo(sessionID) : {};
            const eventParentSessionID = typeof sessionInfo.parentSessionID === "string" ? sessionInfo.parentSessionID : "";
            const parentSessionID = cachedInfo?.parentSessionID || eventParentSessionID;
            const normalizedParentSessionID = normalizeParentSessionID(parentSessionID);
            const isSubagent = normalizedParentSessionID.length > 0;
            const projectPath = readInlineProjectPath(event) || sessionInfo.projectPath || cachedInfo?.projectPath || fallbackProjectPath;
            const title = readInlineTitle(event) || sessionInfo.title || cachedInfo?.title || defaultTitle(projectPath);

            rememberSessionInfo(sessionID, {
              parentSessionID: normalizedParentSessionID,
              projectPath,
              title,
            });

            let kind = resolveKind(type, event?.data);
            if (kind === null && type === "session.renamed") {
              kind = lastKindBySession.get(sessionID) ?? null;
            }

            if (kind === null) {
              writeDebugLog("ignored unsupported event", { type, sessionID });
              return;
            }

            lastKindBySession.set(sessionID, kind);

            writeDebugLog("sending payload", {
              type,
              sessionID,
              parentSessionID: normalizedParentSessionID,
              isSubagent,
              projectPath,
              title,
              kind,
            });

            await sendToPulse({
              agent,
              sessionID,
              projectPath,
              title,
              timestamp: new Date().toISOString(),
              kind,
              parentSessionID: normalizedParentSessionID || undefined,
              isSubagent,
            });

            if (type === "session.deleted" || type === "session.closed") {
              sessionInfoByID.delete(sessionID);
              lastKindBySession.delete(sessionID);
            }
          }

          const controller = new AbortController();
          void (async () => {
            for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
              try {
                await handleEvent(event);
              } catch (error) {
                writeDebugLog("event handling failed", { message: String(error) });
              }
            }
          })();

          return () => controller.abort();
        }

        // OpenCode V1 entrypoint. V1 passes plugin input once and returned hooks.
        function server(input) {
          const fallbackProjectPath = input?.directory ?? process.cwd();
          const sessionInfoByID = new Map();
          const lastKindBySession = new Map();

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

          async function loadSessionInfo(sessionID) {
            if (typeof sessionID !== "string" || sessionID.length === 0) {
              return {};
            }

            try {
              const response = await input.client.session.get({ path: { id: sessionID } });
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

          async function handleEvent(event) {
            const properties = event?.properties ?? {};
            const type = typeof event?.type === "string" ? event.type : "";
            const sessionID = readSessionID(properties);

            if (type === "session.updated" || type === "message.updated") {
              writeDebugLog("ignored metadata-only event", { type, sessionID });
              return;
            }

            if (sessionID.length === 0) {
              writeDebugLog("skipped event without session id", { type });
              return;
            }

            const cachedInfo = sessionInfoByID.get(sessionID);
            const shouldLoadInfo = cachedInfo === undefined || type === "session.created";
            const sessionInfo = shouldLoadInfo ? await loadSessionInfo(sessionID) : {};
            const sessionParentSessionID = typeof sessionInfo.parentSessionID === "string" ? sessionInfo.parentSessionID : "";
            const parentSessionID = readParentSessionID(properties, sessionID) || cachedInfo?.parentSessionID || sessionParentSessionID;
            const normalizedParentSessionID = normalizeParentSessionID(parentSessionID);
            const isSubagent = normalizedParentSessionID.length > 0;
            const projectPath = sessionInfo.projectPath || cachedInfo?.projectPath || fallbackProjectPath;
            const title = sessionInfo.title || cachedInfo?.title || defaultTitle(projectPath);

            rememberSessionInfo(sessionID, {
              parentSessionID: normalizedParentSessionID,
              projectPath,
              title,
            });

            let kind = resolveKind(type, properties);
            if (kind === null && type === "session.updated") {
              kind = lastKindBySession.get(sessionID) ?? null;
            }

            if (kind === null) {
              writeDebugLog("ignored unsupported event", { type, sessionID });
              return;
            }

            lastKindBySession.set(sessionID, kind);

            writeDebugLog("sending payload", {
              type,
              sessionID,
              parentSessionID: normalizedParentSessionID,
              isSubagent,
              projectPath,
              title,
              kind,
            });

            await sendToPulse({
              agent,
              sessionID,
              projectPath,
              title,
              timestamp: new Date().toISOString(),
              kind,
              parentSessionID: normalizedParentSessionID || undefined,
              isSubagent,
            });

            if (type === "session.deleted") {
              sessionInfoByID.delete(sessionID);
              lastKindBySession.delete(sessionID);
            }
          }

          return {
            event: async ({ event }) => {
              await handleEvent(event);
            },
          };
        }

        export default {
          id: "pulse.agent-lights",
          server,
          setup,
        };
        """
    }
}
