# Agent Light Color Mapping Design

## Goal

Swap the visual meaning of the existing agent session lights so:

- `working` renders green
- `idle` renders yellow

The underlying session-state logic does not change. This is a presentation-only update.

## Current Context

- The light-state semantics already exist and are shared across agents through the existing status models
- The actual color mapping is duplicated in at least two UI surfaces:
  - `MenuBarStatusItemView`
  - `AgentStatusManagementView`
- Because the mapping is duplicated, visual rules can drift between the menu bar and the detail panel

## Recommended Approach

Introduce one shared color-mapping helper for agent light states and update all current agent-light renderers to use it.

### Why

- Ensures OpenCode, Codex, and any future agent integrations follow the same visual rule
- Keeps semantic state derivation separate from color presentation
- Removes duplicated UI logic with minimal code movement
- Makes future visual tweaks a one-place change

## Design

### Shared Mapping

Add a small shared helper that maps `AgentSessionLightState` to the AppKit color used for rendering.

Expected mapping after this change:

- `working` -> green
- `idle` -> yellow
- `error` and any other existing states keep their current visual intent unless already centralized alongside this change

The helper should live in a status-domain-adjacent location rather than inside a single view so both current and future agent-light views can consume it.

### View Adoption

Update the current renderers to read from the shared mapping instead of hardcoding colors:

- `MenuBarStatusItemView`
- `AgentStatusManagementView`

No other layout, hit testing, or session-grouping behavior changes are part of this work.

## Data And Behavior Impact

- No status derivation changes
- No storage or persistence changes
- No panel or menu bar interaction changes
- No integration protocol changes for OpenCode or Codex

This work only changes how existing states are painted.

## Error Handling

- If a state does not have a specialized mapping, the shared helper should continue to return the same safe fallback color the current UI expects
- The helper should avoid introducing separate color logic per agent type

## Testing

Update or add focused tests that verify:

- `working` resolves to green through the shared mapping
- `idle` resolves to yellow through the shared mapping
- the menu bar view uses the shared mapping
- the management view uses the shared mapping

Manual verification:

- a working session shows green in the menu bar and the panel
- an idle session shows yellow in the menu bar and the panel
- other states continue to render consistently

## Scope Notes

- This design does not rename statuses
- This design does not change busy/idle inference rules
- This design does not introduce user-configurable colors
