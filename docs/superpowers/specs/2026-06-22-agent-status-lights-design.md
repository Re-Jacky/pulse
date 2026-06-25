# Agent Status Lights Design

Date: 2026-06-22
Status: Drafted for review

## Summary

Pulse will add a live agent-status feature that renders directly in the macOS menu bar as per-agent session lights. The feature is event-driven, not database-driven. Supported agents emit runtime lifecycle events to Pulse through plugins, hooks, or MCP-compatible integrations, and Pulse turns those events into persistent menu bar light slots.

The menu bar UI has two layers:

- an agent group identified by the agent icon
- a set of session light slots inside that group

Each session slot represents one known runtime session and stays visible after work stops until the user removes it. This lets users monitor multiple concurrent projects while avoiding false assumptions about whether an idle session is fully finished or merely waiting.

V1 targets OpenCode and Codex. The architecture should be extensible to Claude Code later without redesigning the Pulse-side model.

## Goals

- Show agent working state directly in the macOS menu bar without requiring the Pulse panel to be open.
- Support multiple concurrent sessions per agent and preserve a stable visual mapping between sessions and lights.
- Distinguish `working`, `idle`, and `error` states with clear traffic-light colors.
- Keep idle sessions visible until the user explicitly removes them.
- Avoid historical or inferred polling sources such as usage databases for live runtime state.
- Use a plugin or hook based integration model that can support multiple agent ecosystems consistently.

## Non-Goals

- Deriving live state from SQLite databases, transcript polling, or log scraping in V1.
- Auto-deleting finished sessions from the menu bar.
- Making the existing Pulse panel the primary surface for live status.
- Supporting unsupported agents without an installed Pulse-compatible plugin or hook.
- Building a generalized notification center for all agent event types in V1.

## Current Context

Pulse already has:

- a menu bar status item owned by `AppDelegate`
- a custom panel for detailed product UI
- existing agent concepts for OpenCode and Codex in the Agent Usage feature
- no live runtime integration layer for agent status

The current Agent Usage implementation is read-only and historical. That system should remain separate from this new runtime-status feature so Pulse does not mix live agent state with usage-analysis state.

## User Experience

### Menu bar layout

The menu bar status item remains a single Pulse-owned item, but it will render custom content instead of only the current CPU symbol.

The item layout is:

- Pulse base icon or compact Pulse mark
- OpenCode group
- Codex group

Each agent group contains:

- the agent icon
- one or more session slots rendered as small lights

Default startup state for each enabled supported agent:

- agent icon
- one empty placeholder slot

This means users can discover the feature immediately, even before the first live session is observed.

### Light states

Each session slot is rendered as one of four visual states:

- `empty` - hollow placeholder light
- `working` - orange
- `idle` - green
- `error` - red

State meaning:

- `working` means the agent is actively generating, executing, or otherwise performing work
- `idle` means the agent is not currently working, including waiting for user input or having completed a task
- `error` means the agent reported a failed state
- `empty` means no session is currently assigned to that slot

### Multi-session behavior

Each discovered live session gets its own slot inside its agent group.

Examples:

- one OpenCode session working and one idle: `OpenCode icon + orange + green`
- three Codex sessions idle, working, and error: `Codex icon + green + orange + red`

Slots do not reorder when the underlying session state changes. Stable positioning is important so users can build a reliable mental mapping between projects and lights.

### Finished and waiting sessions

Pulse does not attempt to infer whether an idle session is permanently finished.

Rules:

- when a session becomes idle, its light turns green and remains visible
- when a session is waiting for user input, it is also green
- when a session errors, its light turns red and remains visible
- Pulse does not auto-remove the light just because the agent stopped working

### Manual deletion

Because idle cannot be assumed to mean permanently done, users need explicit cleanup controls.

V1 must support:

- deleting an individual slot
- clearing idle slots for one agent
- clearing all slots for one agent

Manual deletion removes the slot and its persisted mapping. After cleanup, Pulse must still keep at least one empty placeholder slot visible per enabled agent group.

### Session identification

The menu bar lights alone cannot show a full project name for every session. Pulse therefore needs a management surface that explains which slot corresponds to which project or thread.

The detailed management surface may live in the existing Pulse panel or a dedicated status-management popover, but the live lights themselves remain directly visible in the menu bar.

That management surface should show, for each slot:

- agent
- project name
- optional session or thread title
- current state
- last update time
- delete action

## Integration Model

### Source of truth

Live status must come from explicit runtime events emitted by supported agents through a Pulse-compatible integration.

V1 supported integration types:

- OpenCode plugin
- Codex hook integration

Future compatible types may include:

- Claude Code hook integration
- MCP-backed helper integrations for agents that can emit session lifecycle events

No database reads are used to determine live status for this feature.

### Why hooks and plugins

This approach satisfies the requirement that Pulse should reflect agent sessions running anywhere on the machine, not only those launched from Pulse.

It also gives Pulse access to explicit lifecycle semantics, which are better than trying to infer state from file changes.

## Pulse Runtime Architecture

Pulse will add a dedicated runtime-status subsystem, separate from Agent Usage.

### Core components

- `PulseAgentStatusServer`
  A local endpoint owned by Pulse that receives normalized status events from agent integrations.

- `AgentStatusBridgeManager`
  Starts the local server, validates incoming events, and routes them into the store.

- `AgentSessionSlotStore`
  The source of truth for agent groups and session slots. Owns persistence, slot assignment, deletion, and layout ordering.

- `AgentGroupStatus`
  The in-memory model for one agent's icon, enabled state, and slots.

- `AgentSessionSlot`
  The in-memory model for one menu bar light slot.

- `MenuBarStatusRenderer`
  Produces the status item's custom AppKit view from the current slot store state.

### Separation from Agent Usage

The existing Agent Usage store and database query code remain unchanged in responsibility:

- Agent Usage = historical analytics
- Agent Status Lights = live runtime state

The two features may share agent identifiers such as `openCode` and `codex`, but they should not share the same store or refresh triggers.

## Data Model

### Agent identifiers

Pulse should use a stable agent identifier enum aligned with supported runtime integrations:

- `openCode`
- `codex`

The design should leave room for future cases such as `claudeCode`.

### Agent session slot

Each visible menu bar light is represented as a persistent slot.

Required fields:

- `slotID`
- `agent`
- `sessionID`
- `projectPath`
- `projectName`
- `title`
- `state`
- `lastTransitionAt`
- `lastSeenAt`
- `isPlaceholder`

State enum:

- `empty`
- `working`
- `idle`
- `error`

Notes:

- `sessionID` is optional for empty placeholder slots
- `projectName` is derived from the path for compact display in management UI
- `lastSeenAt` helps with reconnect and stale-session logic

### Agent group status

Required fields:

- `agent`
- `isEnabled`
- `icon`
- `slots`
- `overflowCount`

## Slot Assignment Rules

Slots are assigned by stable session identity, not by transient event ordering.

Rules:

1. If an incoming event matches an existing slot by `agent + sessionID`, update that slot in place.
2. Otherwise, if the agent group has an empty placeholder slot, assign the new session to the first empty slot.
3. Otherwise, append a new slot to the end of the group.
4. Slot order remains stable until the user explicitly deletes a slot.

This prevents visual jumping and preserves user recognition across repeated state changes.

### Startup rules

On first launch or when no stored slots exist:

- create one placeholder slot for each enabled supported agent

On later launches:

- restore previously persisted slots
- if an enabled agent group has zero slots after restore, create one placeholder slot

### Deletion rules

Deleting a slot:

- removes its persisted record
- removes its session mapping
- collapses later slots leftward in the internal array

After deletion:

- if the group would otherwise become empty, insert one placeholder slot

## Event Contract

Pulse should define a normalized event schema that each agent integration translates into.

### Required event kinds

- `session.started`
- `session.working`
- `session.idle`
- `session.error`
- `session.closed`

### Required event fields

- `agent`
- `sessionID`
- `projectPath`
- `title`
- `timestamp`

Optional fields:

- `message`
- `errorCode`
- `metadata`

### State mapping

Pulse maps incoming event kinds to slot state as follows:

- `session.started` -> create or update slot, initial state defaults to `working` unless integration explicitly marks idle
- `session.working` -> `working`
- `session.idle` -> `idle`
- `session.error` -> `error`
- `session.closed` -> `idle`

`session.closed` does not delete the slot. It only records that the session is no longer actively working.

### Integration-specific translation

Each agent integration is responsible for mapping native events into this normalized contract.

Examples:

- OpenCode `session.idle` native event maps to Pulse `session.idle`
- Codex `Stop` hook maps to Pulse `session.idle`
- Codex failure-related hook output maps to Pulse `session.error`
- waiting for user input must map to Pulse `session.idle`

## Menu Bar Rendering Rules

### Visual structure

Each enabled agent group is rendered left to right as:

- agent icon
- visible session slots
- optional overflow indicator

Example:

- `OpenCode icon + orange + green + empty`
- `Codex icon + red + green + green + +2`

### Width management

Menu bar width is limited, so Pulse must constrain slot rendering.

V1 rule:

- show up to a fixed number of visible slots per agent group
- display any additional slots as `+N`

The exact cap can be tuned during implementation, but the design target is three or four visible slots per agent.

### Accessibility and discoverability

The menu bar item should expose a descriptive accessibility label that summarizes each group, for example:

- `OpenCode: 1 working, 1 idle. Codex: 1 error, 2 idle.`

If macOS tooltip behavior is used, it should match the same summary.

## Management Surface

Even though the lights live in the menu bar, users need a reliable way to inspect and manage them.

V1 management surface requirements:

- list all slots grouped by agent
- show project name and optional title for each slot
- show state and last update time
- support deleting one slot
- support clearing idle slots per agent
- support clearing all slots per agent

This management surface may be added to the existing Pulse panel, because that does not conflict with the requirement that live lights themselves must be directly visible in the menu bar.

## Persistence

Pulse should persist slot state locally so the menu bar layout survives app restarts.

Persist:

- agent group membership
- slot order
- session mapping
- last known state
- project metadata
- timestamps

Recommended storage:

- lightweight app-owned persistence such as `UserDefaults` for V1 if the structure stays simple
- or a small JSON file under a Pulse-owned runtime directory if implementation needs more control

Persistence must remain independent from the Agent Usage database readers.

## Error Handling

### Integration missing

If the user enables the feature for an agent but does not install the required plugin or hook integration:

- the menu bar still shows the agent icon and one empty placeholder slot
- the management surface explains that no live events are being received
- Pulse should not attempt fallback scraping

### Malformed events

If an integration sends invalid payloads:

- reject the event
- keep existing slot state unchanged
- surface a debug-friendly error in logs

### Stale sessions

V1 should be conservative about state expiration.

Rules:

- Pulse should not auto-delete stale slots
- if an integration disconnects unexpectedly, the slot remains in its last known state until a new event arrives or the user removes it

This is slightly sticky, but it is more aligned with the product requirement than silently hiding a session the user still cares about.

## Settings

Pulse should add a dedicated `Agent Lights` tab in the Settings window. This tab is separate from the existing `Agent Usage` settings because the two features have different responsibilities and data sources.

V1 `Agent Lights` settings should include:

- `Enable Agent Lights` feature toggle
- per-agent enable toggles for supported agents
- integration setup guidance for OpenCode and Codex
- cleanup actions for persisted slots

Feature enable behavior:

- when `Enable Agent Lights` is off, no live-status agent groups are shown in the menu bar
- when `Enable Agent Lights` is on, only enabled agents show menu bar groups
- each enabled agent shows at least icon plus one placeholder slot
- disabling one agent hides only that agent's group without affecting other enabled agents

The `Agent Usage` tab remains independent:

- turning `Agent Usage` on does not implicitly enable `Agent Lights`
- turning `Agent Lights` on does not implicitly enable `Agent Usage`
- agent selection for one feature does not automatically change selection for the other feature

## Testing Strategy

### Unit tests

- slot assignment for new and returning sessions
- placeholder slot reuse
- stable ordering across state changes
- manual deletion behavior
- placeholder reinsertion after clearing all slots
- event-to-state mapping
- per-agent overflow calculation

### UI and integration verification

- status item renders agent groups correctly at startup
- first session replaces placeholder slot instead of appending after it
- multiple sessions append in stable order
- idle and error sessions remain visible after transitions
- deleting a slot updates the menu bar immediately
- clearing all slots restores one placeholder per enabled agent
- missing integration still shows placeholder and guidance

## Implementation Direction

The design should assume the following defaults unless implementation proves a concrete macOS limitation:

- keep a compact Pulse-owned base icon at the left edge of the status item and append agent groups after it
- use a lightweight local socket based transport for the V1 event server so integrations can send events without deep app-coupled APIs
- show integration setup guidance in Settings and also show a short missing-integration hint in the management surface when no events are arriving
- cap visible slots at four per agent group in V1 and represent additional sessions with `+N`

## Recommendation

Implement the feature as a new Pulse runtime-status subsystem with persistent per-session slots and a plugin or hook based event contract. Keep the menu bar as the always-visible live display surface, and use a secondary management surface only for inspection and cleanup.
