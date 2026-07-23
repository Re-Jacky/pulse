# Agent Status Integrations

This note describes how Pulse receives and renders live agent session status for OpenCode and Codex.

## Overview

Pulse models live agent state in three layers:

1. Agent-specific integration adapters emit normalized session events.
2. `PulseAgentStatusServer` receives those events on a local loopback TCP port.
3. `AgentStatusStore` merges the events into visible menu bar lights and panel session slots.

The install and uninstall flow for those adapters is owned by `AgentIntegrationManager`.

## Integration Revisions

Each generated integration file carries an independent revision marker in its header:

- OpenCode plugin: `PULSE_OPENCODE_PLUGIN_VERSION=opencode-plugin-v1`
- Codex hook: `PULSE_CODEX_HOOK_VERSION=codex-hook-v3`
- Shared sender: `PULSE_AGENT_SENDER_VERSION=sender-v1`

These are opaque integration revisions, not the Pulse marketing version. They are bumped only when the corresponding generated code or event contract changes, so a normal Pulse app release does not make every installed integration appear outdated.

`AgentIntegrationManager` compares each installed marker exactly with the expected revision. OpenCode requires a current plugin and sender; Codex requires a current hook and sender plus a Pulse hook entry in `hooks.json`. Missing integrations are reported as not installed, while existing Pulse-managed files with missing or old markers are reported as outdated.

At app startup, Pulse automatically reinstalls integrations reported as outdated. Reconciliation is limited to files identified as Pulse-managed, preserves user-owned Codex hook entries, and does not install integrations that the user has never enabled.

## Installed Files

### OpenCode

- Plugin: `~/.config/opencode/plugins/pulse-agent-lights.ts`
- Shared sender: `~/.pulse-agent-lights/pulse-agent-event-sender.sh`

The OpenCode plugin listens to OpenCode runtime events, resolves missing metadata through `client.session.get(...)`, normalizes parent lineage, and sends JSON payloads to Pulse.

### Codex

- Hook script: `~/.codex/hooks/pulse-agent-lights-hook.sh`
- Hook config: `~/.codex/hooks.json`
- Shared sender: `~/.pulse-agent-lights/pulse-agent-event-sender.sh`

Pulse merges its Codex entries into the shared `hooks.json` file instead of owning a standalone config file. That preserves any existing user hooks and lets uninstall remove only the Pulse-managed commands.

## Event Flow

### OpenCode path

1. OpenCode raises a runtime event.
2. The Pulse-managed plugin inspects the event and extracts:
   - `sessionID`
   - `projectPath`
   - `title`
   - `parentSessionID`
3. The plugin treats only `ses_*` parent IDs as true parent sessions.
4. The plugin maps supported events into Pulse kinds:
   - `session.created` -> `session.working`
   - `session.status(idle)` -> `session.idle`
   - `session.status(other)` -> `session.working`
   - `session.idle` -> `session.idle`
   - `session.error` -> `session.error`
   - `session.deleted` -> `session.closed`
5. Metadata-only events such as `session.updated` and `message.updated` are ignored for state transitions.
6. The plugin sends one newline-delimited JSON payload to the shared sender.

### Codex path

1. Codex runs the Pulse-managed hook.
2. Codex sends hook JSON on stdin, including `hook_event_name`, `session_id`, and `cwd`.
3. The hook maps:
   - `UserPromptSubmit` -> `session.working`
   - `SubagentStart` -> `session.working`
   - `SubagentStop` -> `session.idle`
   - `Stop` -> `session.closed`
4. Subagent events are marked with `isSubagent = true` and include `parentSessionID` when Codex provides it.
5. For `UserPromptSubmit`, the hook also forwards `transcriptPath` and `turnID` when Codex provides them.
6. The hook forwards one normalized JSON payload to the shared sender.
7. The hook returns `{ "continue": true }` so it never blocks Codex execution.

Current Codex limitation:

- Some Codex builds do not reliably emit a closing `Stop` hook when a user manually interrupts a turn.
- Codex transcripts can still record the interrupted turn as an `event_msg` payload with `type = "turn_aborted"`.
- When Pulse receives a Codex `session.working` event with both `transcriptPath` and `turnID`, it performs a short transcript-backed check for that exact aborted turn before demoting the session to `idle`.
- Pulse intentionally avoids a blind `idle` timeout for Codex; the fallback requires transcript evidence for the matching turn.

## Shared Sender

`PulseAgentEventSenderTemplate` generates a small shell script that forwards one event per process to `127.0.0.1:45821`.

It supports two input forms:

- Structured JSON payload in `$1`
- Positional arguments used by older adapters

This script is intentionally shared so uninstall safety and versioning stay centralized.

## Store Semantics

`AgentStatusStore` is the source of truth for visible lights and session rows.

Important rules:

- Top-level sessions create or update visible slots.
- Subagents are not shown as their own slots.
- A parent remains `working` while any real child subagent is still active.
- Subagent errors do not promote the parent to `error`.
- Out-of-order delivery is expected because the sender launches separate processes and TCP connections per event.

To handle that last point, the store tracks the latest event version per session and ignores stale events. When two events share the same timestamp, more terminal states win over `working`, so a late-arriving `working` cannot overwrite a same-time `idle`.

## Debug Logging

Debug logging is disabled by default.

When needed, enable it by creating this file:

- `~/.pulse-agent-lights/debug-enabled`

With that file present:

- OpenCode plugin logs to `~/.pulse-agent-lights/logs/opencode-plugin.log`
- Shared sender logs to `~/.pulse-agent-lights/logs/pulse-agent-sender.log`

Without that file, neither component writes logs.

## Key Source Files

- `pulse/Managers/AgentIntegrationManager.swift`
- `pulse/Managers/OpenCodeIntegrationInstaller.swift`
- `pulse/Managers/CodexIntegrationInstaller.swift`
- `pulse/Managers/CodexHooksManifest.swift`
- `pulse/Managers/PulseAgentEventSenderTemplate.swift`
- `pulse/Managers/PulseAgentStatusServer.swift`
- `pulse/Managers/AgentStatusStore.swift`
