# Agent Usage Design

## Goal

Add an optional OpenCode-powered usage analysis feature to Pulse. The feature starts disabled in Settings, adds an `Agent` tab to the main panel when enabled, and lets the user inspect token usage at three scopes:

- all OpenCode sessions on the machine
- one project
- one session within a selected project

The first release should prioritize a compact menu bar-friendly experience and rely only on OpenCode's local database.

## Current State

- Pulse currently has two main panel tabs: `Overview` and `Processes`.
- The main panel is a fixed-width custom `NSPanel` created in `AppDelegate.makePanel()`.
- Settings currently expose only a `Theme` section.
- There is no persisted feature flag for optional analysis features.
- OpenCode local data exists outside the Pulse repo in `~/.local/share/opencode/opencode.db`.
- OpenCode's CLI behavior appears cwd-sensitive for session listing, so the database should be treated as the source of truth for global discovery.

## Naming

- Settings section: `Agent Usage`
- Main panel tab: `Agent`
- Agent selector label: `Agent`
- First supported agent option: `OpenCode`

## Feature Toggle Behavior

- `Agent Usage` is `Off` by default.
- When `Off`:
  - the main panel keeps its current 2-tab layout
  - no OpenCode data is loaded
- When `On`:
  - the main panel adds a third `Agent` tab
  - the panel opens at a wider default width so the 3-tab header and agent controls have enough space
  - OpenCode data loads only when the panel opens, when the Agent tab becomes visible, or when the user presses `Refresh`

This feature should be controlled by a dedicated observable settings object or equivalent persisted settings state, similar in spirit to `ThemeManager`.

## Main Panel Layout

- Normal mode keeps the existing panel sizing and 2-tab segmented header.
- Agent-enabled mode widens the panel enough for:
  - `Overview`, `Processes`, and `Agent` segmented tabs
  - an agent selector row
  - searchable project and session selectors
  - a compact detail section

The Agent-enabled width should be modestly larger than the current panel, not a dramatic expansion into a desktop-style analytics window. Session details should be handled with stacked sections instead of additional width growth.

## Agent Tab Interaction Model

The Agent tab is driven by one active scope:

- `All Projects`
- one project
- one session within the selected project

The same active scope drives both the compact summary row and the detailed data section so the screen never shows mismatched totals.

### Header Row

- left side: `Agent` selector
- available options in v1:
  - `OpenCode`
- right side: `Refresh` control

### Project Selector

- always visible
- default option: `All Projects`
- searchable
- ranked by total token usage descending
- each item shows:
  - primary text: short project name derived from the last path component
  - secondary text: token usage preview plus full path

Suggested secondary format:

```text
2.97M total tokens • 49 sessions • /Users/zyao/Desktop/pulse
```

### Session Selector

- hidden while `All Projects` is selected
- becomes visible after a specific project is selected
- searchable
- filtered to sessions from the selected project
- ranked by total token usage descending within that project
- each item shows:
  - primary text: session title
  - secondary text: token usage preview plus updated time and model hint

When the project changes:

- any selected session is cleared
- the scope falls back to the selected project's aggregate view

When the selected project or session no longer exists after refresh:

- missing project resets to `All Projects`
- missing session clears the session selection and falls back to the project scope

## Scope-Sensitive Summary

The compact summary row should always reflect the current scope, not permanent global totals.

Rules:

- `All Projects` selected:
  - summary reflects all OpenCode sessions
- specific project selected and no session selected:
  - summary reflects that project's aggregate
- specific session selected:
  - summary reflects that session

Primary summary metrics:

- `Total Tokens`
- `Input Tokens`
- `Output Tokens`
- `Cache Read Tokens`

Secondary compact metadata:

- `Reasoning Tokens`
- `Sessions`
- `Last Updated`
- `Cost` only when the aggregate cost is greater than zero

## Detail Section

The detail section updates with the current scope and always includes a full token breakdown.

### Usage Block

Always show:

- `Total Tokens`
- `Input Tokens`
- `Output Tokens`
- `Reasoning Tokens`
- `Cache Read Tokens`
- `Cache Write Tokens`

`Total Tokens` is computed as:

```text
input + output + reasoning + cacheRead + cacheWrite
```

The UI should avoid labeling this as billed usage because OpenCode stores token classes separately and providers may bill them differently.

### Context Block

For `All Projects`:

- `Projects Count`
- `Sessions Count`
- `Last Updated`

For `Project`:

- `Project Name`
- `Full Path`
- `Sessions Count`
- `Last Updated`

For `Session`:

- `Title`
- `Full Path`
- `Agent`
- `Provider / Model`
- `Created`
- `Last Updated`

## By-Model Breakdown

OpenCode's `session.model` field is stored as JSON and can be aggregated at the session level by:

- `providerID`
- `id`
- `variant`

This supports a `By Model` breakdown for:

- `All Projects`
- `Project`

It should not be presented as a true per-model breakdown for a single session in v1 because a session may switch models over time while the session row stores only one summarized model identity.

Recommended v1 behavior:

- include a compact `By Model` sub-section for `All Projects` and `Project`
- in `Session` scope, show only `Provider / Model` metadata rather than a model breakdown

## OpenCode Data Source

Use `~/.local/share/opencode/opencode.db` as the canonical source for discovery and aggregation.

Primary `session` columns used in v1:

- `title`
- `directory`
- `agent`
- `tokens_input`
- `tokens_output`
- `tokens_reasoning`
- `tokens_cache_read`
- `tokens_cache_write`
- `cost`
- `time_created`
- `time_updated`
- `model`

Model metadata should be parsed from the `model` JSON blob:

- `providerID`
- `id`
- `variant`

The first release should not depend on OpenCode CLI output for global discovery.

## Data We Are Explicitly Not Relying On

- `session_input` for prompt counts, because it is empty in the observed local database
- `session_message` as a primary analytics source, because it mainly contains switch events in the observed data
- transcript parsing for v1 summaries
- exact within-session multi-model attribution

`message` and `part` tables may be useful later for richer charts or per-step analysis, but they are not required for the initial feature.

## Loading And Refresh

- No background timer
- Load data when:
  - the panel opens and Agent Usage is enabled
  - the Agent tab becomes visible
  - the user presses `Refresh`

Loading states:

- first load shows a lightweight loading state
- refresh keeps current data visible and shows a smaller in-place refreshing indicator

The current project and session selections should be preserved across refreshes when possible.

## Error And Empty States

If Pulse cannot read OpenCode data, the Agent tab should remain visible and show a safe fallback state instead of failing silently.

User-facing empty/error state should support:

- missing database
- locked or busy database
- read failure
- no OpenCode sessions found

The state should include:

- a short explanation
- a `Refresh` action
- the expected OpenCode DB location for debugging

## Settings Window Changes

Add an `Agent Usage` section to the settings sidebar.

The section should:

- explain what the feature does in one or two short sentences
- present a simple on/off control
- default to `Off`

This section does not need provider-specific settings in v1.

## Non-Goals

- Codex support
- background auto-refresh
- charts or historical timelines
- export or copy actions
- exact within-session multi-model attribution
- CLI-based session discovery
- agent support beyond OpenCode in the first release

## Verification

Build:

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Manual checks:

- `Agent Usage` appears in Settings and defaults to `Off`
- turning the feature `On` adds the `Agent` tab
- turning the feature `Off` removes the `Agent` tab
- the panel widens when the feature is enabled
- the Agent tab shows `OpenCode` with a refresh control
- the project selector defaults to `All Projects`
- project options are searchable and ranked by total token usage descending
- selecting a project reveals the session selector
- session options are searchable and ranked within the selected project
- selecting `All Projects`, a project, or a session updates both summary and detail data to the same scope
- the detail section always shows the full token breakdown:
  - total
  - input
  - output
  - reasoning
  - cache read
  - cache write
- global and project scopes can show a `By Model` breakdown
- session scope shows `Provider / Model` metadata instead of a model breakdown
- missing or unreadable OpenCode data shows a friendly fallback state instead of breaking the panel
