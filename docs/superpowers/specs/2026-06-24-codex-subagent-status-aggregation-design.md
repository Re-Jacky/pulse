# Codex Subagent Status Aggregation Design

## Goal

Make Codex live session status follow the same subagent rule already established for OpenCode:

- Codex subagents must not appear as standalone visible sessions in Pulse
- Codex subagent activity may still affect the visible parent session state
- A parent session stays `working` while any Codex subagent is still active

This is a live-status event normalization fix, not a change to the visible panel model.

## Current Context

- `AgentStatusStore` already supports parent-child aggregation through the shared event contract fields:
  - `isSubagent`
  - `parentSessionID`
- When those fields are present and correct, the store suppresses child slots and rolls active child work into the parent session state
- OpenCode already uses this pattern successfully
- Codex currently exposes some child sessions as standalone visible slots, which suggests its hook is not emitting parent-child metadata in the shape the shared store expects

## Recommended Approach

Fix Codex at the integration boundary so its hook emits normalized subagent metadata that matches the existing shared store contract.

### Why

- Keeps agent-specific quirks out of `AgentStatusStore`
- Reuses the same aggregation logic already verified for OpenCode
- Preserves one consistent event contract across agents
- Avoids UI-only hiding that would leave the underlying live state incorrect

## Design

### Codex Hook Contract

The Codex hook must emit subagent events with:

- `isSubagent = true`
- a stable `parentSessionID` that identifies the owning main Codex session

Main-session events must continue to emit as primary sessions:

- `isSubagent = false`
- `parentSessionID = nil`

If Codex provides hook contexts with child-session identifiers or nested lifecycle events, the integration layer should normalize them into this shared payload format before sending them to Pulse.

### Store Behavior

No new Codex-specific slot model should be introduced.

Expected shared-store behavior remains:

- primary sessions create or update visible slots
- child sessions do not create visible slots
- child `working` keeps the parent `working`
- child `idle` or `stop` removes that child from the parent active-child set
- child `error` does not promote the parent to `error`

This matches the current OpenCode rule and should remain shared across agents.

### Receiver Behavior

The event receiver should continue validating the shared payload as it does now.

If a small defensive normalization step is needed for Codex payload shape before decode, it should remain minimal and only exist to preserve the same shared event contract. The preferred fix remains the hook output itself.

## Data And Behavior Impact

- No panel layout changes
- No menu bar hit-testing changes
- No persistence model changes
- No agent-usage database changes
- No new session categories in the UI

This change is limited to live event correctness for Codex subagents.

## Error Handling

- If a Codex child event arrives without a usable `parentSessionID`, Pulse should not invent a parent heuristically
- Invalid child metadata should be treated as an integration bug to fix at the hook boundary
- The receiver must continue rejecting malformed payloads rather than silently guessing relationships

## Testing

Add or update focused tests that verify:

- a Codex primary session plus a Codex child `working` event yields one visible parent slot in `working`
- a Codex child event does not create a second visible slot
- a Codex child `idle` or `stop` event lets the parent fall back to its own base session state when no active children remain
- a Codex child `error` does not force the parent into `error`
- the Codex hook installer/template preserves the expected normalized child metadata fields

Manual verification:

- start a Codex main session with subagent work
- confirm Pulse shows only the main Codex session
- confirm the main session stays `working` while any Codex subagent is still active
- confirm child completion returns the main session to its own primary state

## Scope Notes

- This design does not add a separate Codex child-task UI
- This design does not change OpenCode behavior
- This design does not alter Codex usage/history aggregation from SQLite or transcripts
