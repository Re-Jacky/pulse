# Agent Status Per-Agent Panel Design

## Goal

Change the Agent Lights popup so it shows one agent at a time instead of stacking all agent groups in one panel.

The selected agent is determined only by the menu bar click target:

- Clicking an agent's icon and lights is treated as one click zone
- That click opens the Agent Lights panel for that specific agent
- If the panel is already open, the content switches in place to the clicked agent
- There is no in-panel agent switcher and no "last used agent" fallback

## Current Context

- Pulse already uses a dedicated floating `agentStatusPanel` owned by `AppDelegate`
- The menu bar lights are rendered as grouped agent sections in `MenuBarStatusItemView`
- The management panel currently renders every `AgentStatusGroup` in one scroll view

This means we can keep the existing panel/window lifecycle and only change how clicks are resolved and how content is filtered.

## Recommended Approach

Use one persistent `agentStatusPanel` plus a selected-agent state in `AppDelegate`.

### Why

- Fits the existing AppKit ownership model cleanly
- Avoids multiple floating windows and extra dismissal rules
- Keeps click behavior deterministic and easy to reason about
- Minimizes UI churn compared with rebuilding or reopening a fresh panel each time

## Interaction Design

### Menu Bar Hit Testing

Each visible agent group becomes one tappable/clickable zone composed of:

- the agent icon
- the visible session lights for that agent
- the overflow marker such as `+1`, when present

Clicks on any part of that zone select that agent.

### Panel Behavior

- If the panel is closed, clicking an agent group opens it for that agent
- If the panel is open, clicking the same or another agent group keeps the same window and updates the content
- Outside-click dismissal remains unchanged
- Right click keeps the same behavior as left click unless a separate context-menu interaction is added later

## Data Flow

1. `MenuBarStatusItemView` maps rendered geometry for each visible agent group
2. A click resolves to `AgentStatusAgent`
3. `AppDelegate` receives that agent selection
4. `AppDelegate` opens the panel if needed and updates selected-agent state
5. `AgentStatusManagementView` renders only the matching group

No live status logic changes are required for this feature. Existing per-agent grouping and subagent aggregation remain the source of truth.

## Component Changes

### `MenuBarStatusItemView`

- Track hit regions for visible agent groups
- Expose an agent-specific click callback rather than a generic panel toggle callback
- Keep width calculation and rendering behavior unchanged

### `AppDelegate`

- Add selected-agent state for the agent-status panel
- Replace generic agent-panel toggle handling with:
  - resolve clicked agent
  - open panel for that agent
  - switch current panel content when already visible

### `AgentStatusManagementView`

- Accept or read the selected agent
- Render a single group's integration card and slots instead of iterating over all groups
- Keep existing actions such as clear idle, clear all, and delete slot scoped to the visible agent

## Error Handling

- If a click lands outside any visible agent group, do nothing
- If the selected agent has no real slots, show its existing placeholder state
- If an agent becomes hidden in settings while selected, close the panel or fall back to no visible content; implementation should prefer closing to avoid misleading empty state

## Testing

Add focused coverage for:

- menu bar hit-testing resolves the correct agent zone
- clicking one agent while the panel is open switches content without creating a second panel
- the management view only renders the selected agent's section
- overflow marker remains part of the clickable region

Manual verification:

- click OpenCode group -> OpenCode detail only
- click Codex group while panel is open -> panel switches to Codex detail only
- click outside -> panel dismisses normally
- hidden agents do not open a panel from the menu bar because their group is not rendered

## Scope Notes

- This design does not add a session-exit signal
- This design does not add an in-panel tab or segmented control
- This design does not change how agent states are derived
