# Agent Status Integration Install Design

Date: 2026-06-23
Status: Drafted for review
Depends on: `docs/superpowers/specs/2026-06-22-agent-status-lights-design.md`

## Summary

Pulse will add install and activation controls for Agent Lights directly inside the standalone Agent Lights panel. The panel will let users install, reinstall, recheck, and uninstall the OpenCode plugin and the Codex hook required for live session lights.

V1 uses a machine-wide integration model:

- OpenCode installs a global Pulse-managed plugin
- Codex installs a global Pulse-managed hook
- both integrations call the same Pulse-managed local sender

This keeps live status event delivery consistent across agents and matches the requirement that Pulse should reflect sessions running anywhere on the machine, even if they were not started from Pulse.

## Goals

- Let users set up Agent Lights without leaving Pulse or editing config files manually.
- Keep integration state visible in the Agent Lights panel next to the session slots it powers.
- Use agent-native extension surfaces instead of database polling.
- Keep the adapter code for each agent thin and route both through one shared sender.
- Provide clear in-app guidance for any required manual activation steps.
- Support future agents such as Claude Code without redesigning the Pulse-side model.

## Non-Goals

- Automatic Codex trust approval from Pulse in V1.
- Project-local install modes in V1.
- Deep-linking into Codex activation flows in V1.
- Rich diagnostics for every possible user-customized agent environment in V1.
- Replacing the existing menu bar slot model or event contract.

## User Experience

### Panel layout

Each agent section in the Agent Lights panel will contain two stacked areas:

1. `Integration`
   Shows install state, setup guidance, and lifecycle actions for that agent.
2. `Sessions`
   Shows the session slots already designed for Agent Lights.

This keeps setup and status connected while preserving the existing session cleanup controls.

### Integration card

Each supported agent gets one integration card above its slots.

The card shows:

- official agent icon
- agent name
- integration status
- one short guidance block
- primary action button
- supporting actions when relevant

### Supported actions

OpenCode:

- `Install Plugin`
- `Reinstall`
- `Recheck`
- `Uninstall`

Codex:

- `Install Hook`
- `Reinstall`
- `Recheck`
- `Uninstall`

### Status states

Pulse tracks integration health separately from session state.

Shared states:

- `Not Installed`
- `Installed`
- `Outdated`
- `Install Failed`

Codex-specific activation state:

- `Installed - Activate in Codex`

OpenCode-specific restart state:

- `Installed - Restart OpenCode`

These states describe install readiness only. They do not imply that a session is currently active.

### Inline guidance

Pulse must show required follow-up steps inline instead of hiding them behind another click.

OpenCode guidance:

- `Restart OpenCode so the Pulse plugin is loaded.`

Codex guidance:

- `Open any Codex session.`
- `Run /hooks.`
- `Find the Pulse hook.`
- `Trust or enable it.`

Codex guidance is always visible when the hook is installed because the activation step is required in V1.

## Installation Scope

V1 uses machine-wide install targets only.

Reasons:

- Agent Lights must reflect sessions started elsewhere on the machine.
- A per-project mode would complicate the panel and weaken discoverability.
- Global install keeps OpenCode and Codex behavior conceptually aligned.

If a future version needs project-local installs, that should be introduced as an explicit advanced mode rather than mixed into the default setup flow.

## Architecture

### Pulse-side components

- `AgentIntegrationManager`
  Owns detection, install, reinstall, uninstall, and recheck flows for all supported agents.

- `AgentIntegrationStatus`
  A UI-facing model that describes integration state, guidance, and available actions for one agent.

- `OpenCodeIntegrationInstaller`
  Writes and removes the OpenCode plugin files and reports install state.

- `CodexIntegrationInstaller`
  Writes and removes the Codex hook files and reports install state.

- `PulseAgentEventSender`
  A shared Pulse-managed script or helper used by all supported agent integrations to forward normalized events to Pulse.

The panel view should observe integration status through a dedicated store or manager instead of embedding file-system logic in SwiftUI.

### Existing Pulse runtime

This design does not replace the existing event server or slot store:

- `PulseAgentStatusServer` remains the event receiver
- `AgentStatusStore` remains the slot source of truth

The integration layer exists only to place the right files on disk and help users activate them.

## Shared Event Contract

All supported agent integrations emit the same normalized payload:

```json
{
  "agent": "codex",
  "sessionID": "stable-session-id",
  "projectPath": "/absolute/project/path",
  "title": "human-readable session title",
  "timestamp": "2026-06-23T08:00:00Z",
  "kind": "session.working",
  "message": "optional"
}
```

Rules:

- `sessionID` must be stable for the life of one agent session
- `projectPath` must be absolute
- `title` may be empty but should be supplied when available
- `message` is optional and not required for slot identity

Event mapping remains:

- `session.started` or `session.working` -> orange working light
- `session.idle` or `session.closed` -> green idle light
- `session.error` -> red error light

This contract matches the existing Pulse-side event and slot models.

## Shared Sender Design

### Purpose

Both OpenCode and Codex adapters should call one shared local sender rather than implementing their own socket logic.

### Form

V1 should use a script-based sender, not a compiled helper.

Reasons:

- easier to inspect during debugging
- easier to reinstall and update
- fewer moving parts for v1

### Responsibilities

The sender should:

- accept normalized event fields as arguments or environment variables
- serialize a single newline-delimited JSON payload
- send it to Pulse on `127.0.0.1:45821`
- return quickly
- never fail the agent workflow if Pulse is unavailable

### Failure policy

If the sender cannot reach Pulse:

- do not block or crash the agent hook or plugin
- optionally log a lightweight local error for support debugging
- silently skip the event from the agent's point of view

Agent status lights are convenience telemetry, not a hard dependency.

## OpenCode Plugin Design

### Install target

Pulse installs a global OpenCode plugin into the standard global plugin location used by OpenCode.

### Responsibilities

The OpenCode plugin should:

- subscribe to OpenCode lifecycle events
- map OpenCode active work to `session.working`
- map waiting-for-user or completed states to `session.idle`
- map failures to `session.error`
- call the shared Pulse sender with the normalized payload

### Plugin shape

The plugin should be a thin adapter:

- read the OpenCode event
- derive `sessionID`, `projectPath`, and `title`
- translate event type into Pulse event kind
- invoke the shared sender

The plugin should not embed Pulse socket code or persistence logic.

### Activation model

OpenCode activation is expected to be lightweight.

After installation, Pulse shows:

- `Installed - Restart OpenCode`

This acknowledges that the plugin is on disk but may not yet be loaded by a running OpenCode process.

## Codex Hook Design

### Install target

Pulse installs a global Codex hook script and the matching global hook configuration in the user Codex config area.

### Responsibilities

The Codex hook should:

- listen at the hook points that best represent active work and stop or yield transitions
- derive a stable `sessionID`
- derive `projectPath` and `title` from available Codex context
- emit `session.working`, `session.idle`, and `session.error` through the shared sender

### Hook shape

Like the OpenCode plugin, the Codex hook should stay thin:

- read the Codex hook context
- translate it into the normalized Pulse payload
- invoke the shared sender

### Activation model

Codex requires a manual user trust step for non-managed hooks.

Pulse therefore shows:

- `Installed - Activate in Codex`

And inline guidance:

- `Open any Codex session.`
- `Run /hooks.`
- `Find the Pulse hook.`
- `Trust or enable it.`

Pulse does not attempt to automate this trust step in V1.

## Detection Model

Pulse should detect integration state by inspecting the expected installed files and their version markers.

Detection checks:

- expected files exist
- file contents contain the current Pulse-managed version marker
- shared sender exists

Interpretation:

- missing files -> `Not Installed`
- matching files present -> `Installed` or install-follow-up state
- mismatched older files -> `Outdated`
- write or validation failure during install -> `Install Failed`

Pulse should not treat file presence as proof that the integration is actively firing events. It only proves installation on disk.

## Uninstall Model

`Uninstall` removes only Pulse-managed integration files.

Rules:

- remove the OpenCode plugin files installed by Pulse
- remove the Codex hook files installed by Pulse
- remove the shared sender only when no installed agent still depends on it
- do not delete unrelated user plugin or hook files

If Pulse detects files that no longer match the Pulse-managed marker, it should avoid destructive cleanup and instead surface `Outdated` or `Install Failed` with a recommendation to reinstall first.

## Error Handling

Pulse-side install and detection errors should be user-readable but compact.

UI behavior:

- show a one-line failure summary in the integration card
- allow `Reinstall` and `Recheck`
- keep `Uninstall` available when Pulse can identify its managed files

The panel should not expand into a heavy debug console in V1.

## Testing

Add tests for:

- integration status detection for missing, installed, outdated, and failed states
- install payload generation for the OpenCode plugin
- install payload generation for the Codex hook and config
- uninstall behavior for Pulse-managed files only
- Codex activation guidance rendering
- OpenCode restart guidance rendering
- no regressions to existing slot rendering and cleanup behavior

## Recommendation

Recommended V1:

- standalone Agent Lights panel continues to manage session slots
- add one integration card per enabled agent
- install machine-wide only
- use one shared script-based sender
- use thin OpenCode plugin and Codex hook adapters
- show required manual guidance inline, especially for Codex activation

This design is the smallest complete setup flow that matches the live-status architecture already approved for Agent Lights.
