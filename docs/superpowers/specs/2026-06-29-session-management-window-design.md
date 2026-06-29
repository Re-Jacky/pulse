# Session Management Window Design

## Goal

Add a dedicated session-management window to Pulse that lets users browse sessions across agents, inspect full conversation history, and access session-level management actions without changing the existing Agent Usage layout.

This feature is explicitly separate from the current Agent Usage analytics surface. The existing Agent Usage view remains focused on usage summaries, filters, and charts.

## Current Context

- The Agent Usage view already supports source, project, and session selection for `All`, `OpenCode`, and `Codex`
- Pulse currently reads session metadata from:
  - OpenCode local SQLite data
  - Codex local SQLite metadata plus transcript `.jsonl` files
- Pulse can already identify concrete sessions and present per-session usage summaries
- The existing lower session-detail area in Agent Usage is small and optimized for lightweight metadata, not transcript reading or session operations
- A previous handoff-oriented design doc exists, but it is now deprecated and must not be treated as the implementation basis for this feature

## Product Direction

Pulse should keep the current Agent Usage page visually and behaviorally stable.

Instead of expanding that page into a full transcript browser, Pulse should add a separate management surface:

- a `Manage Sessions` button in the Agent Usage header
- available in `All`, `OpenCode`, and `Codex` source modes
- opens a dedicated Pulse-owned management window

This new window becomes the primary place for:

- browsing sessions across agents and projects
- reading full conversation history
- performing session-level management actions
- hosting future context-copy and continuation flows

## Recommended Approach

Create a new settings-style management window with a split layout:

- left panel for session discovery and filtering
- right panel for transcript inspection and session actions

### Why

- Preserves the current Agent Usage dashboard as a clean analytics surface
- Gives transcript history and management actions enough room to be usable
- Avoids forcing one screen to serve both summary analytics and dense transcript work
- Creates a stable home for later features such as `Copy Context`, source-native resume, export, or cleanup

## Window Model

The session-management surface should behave like Settings in ownership and theme integration:

- opened from a dedicated app-controlled window
- reused across repeated opens instead of spawning duplicates
- aligned with the app's current theme and semantic colors
- resizable with a larger default size than Settings

The window should be sized for dense content, not a compact preference form.

Recommended V1 shape:

- default width large enough to comfortably show a session list and transcript at once
- minimum size that still preserves a readable two-pane layout
- standard window chrome and resizing behavior consistent with the existing Settings window approach

## Entry Point

Add `Manage Sessions` to the Agent Usage header.

Behavior:

- visible in `All`, `OpenCode`, and `Codex`
- opens the management window without replacing the current Agent Usage panel
- if the user already has a project, agent, or session selected in Agent Usage, Pulse may use that to seed the initial manager filters, but this is optional for V1

V1 should not require perfect state synchronization between the analytics page and the manager window. Shared defaults are helpful, but the manager must be independently usable.

## Information Architecture

The manager window uses a hybrid source model.

### Top-level navigation

The window should support:

- a unified `All` view across agents
- quick pivots for `OpenCode`
- quick pivots for `Codex`

This is not a separate window per agent. It is one management window with fast narrowing controls.

### Filters

At minimum, the manager supports:

- agent filter
- project filter
- session search or narrowing

The browsing scope is all-time by default. This window is for session management, not ranged usage analytics, so it should not inherit the `Today / 7 Days / 30 Days` framing from Agent Usage unless a later design proves it useful.

## Layout

### Left panel

The left panel is the session browser.

It should include:

- source pivot controls (`All`, `OpenCode`, `Codex`)
- project filter
- session search or list narrowing
- session list rows with compact metadata

Each session row should expose enough information to help the user choose the right session quickly, such as:

- title
- agent
- project or directory name
- updated time
- light secondary metadata such as model or short status where available

The left side is optimized for scanning and changing selection quickly.

### Right panel

The right panel is the selected session workspace.

It should include:

- session header metadata
- transcript viewer
- session management actions

The transcript is the default reading mode. Pulse should show the real session history as faithfully as possible from the underlying local source rather than replacing it with a generated summary-first experience.

## Transcript Presentation

V1 defaults to full transcript reading.

Expected behavior:

- show user and assistant turns in chronological order
- render the transcript as close to the source history as is practical
- preserve clear role boundaries between user and assistant messages

Pulse may normalize the presentation visually, but the transcript reader should not silently replace the source transcript with an aggressively transformed or summarized interpretation.

This matters because users need confidence that the displayed session history is the thing they actually worked on.

## Loading Strategy

Large histories must be handled lazily.

### V1 loading behavior

- load the session list and filter metadata first
- load detailed conversation history only when the user selects a session
- avoid preloading full transcripts for every visible session
- support incremental rendering or pagination for long sessions

The goal is to keep the management window responsive even when the backing transcript source is large.

This lazy-loading rule applies to both agents, even if one source is cheaper to read than the other.

## Session Actions

The right panel also hosts session-level actions.

V1 should reserve space for at least these categories:

- resume
- copy context
- broader management actions

### Resume

V1 supports source-native resume only.

That means:

- OpenCode sessions expose OpenCode-flavored resume actions
- Codex sessions expose Codex-flavored resume actions
- Pulse does not need to guarantee cross-agent continuation in this feature version

This keeps the first version honest and avoids prematurely promising reliable migration semantics before the transcript and context-export model are fully designed.

### Copy Context

`Copy Context` remains intentionally under-specified in this design.

The management window must provide a clear product home for it, but this spec does not lock the copied payload format yet.

Deferred decisions include:

- whether copy defaults to recent turns, full transcript, or selected range
- whether metadata is always included
- whether assistant-only compaction or summarization is applied
- whether copy output should differ by target agent

V1 of the manager should therefore treat `Copy Context` as an action surface with pluggable export behavior rather than baking in one irreversible context format too early.

### Broader management actions

The manager is intended to become the home for operational actions beyond transcript reading.

This spec leaves the exact V1 management action set open, but the layout should anticipate actions such as:

- copy
- resume
- export
- cleanup-oriented operations

The important design constraint is that these actions belong in the manager window, not in the compact Agent Usage dashboard.

## Large Context And Compaction

This feature has two different "large" problems:

- large transcripts for reading
- large contexts for copying or continuing

They should not be solved the same way.

### Reading large transcripts

Use lazy loading and incremental rendering.

### Copying large context

Do not silently compact by default in V1.

Compaction, summarization, or compression may become necessary for `Copy Context` later, but that policy needs separate design because it changes meaning, fidelity, and user trust.

This design intentionally avoids auto-generated compact context as the default transcript experience.

Future copy-context strategies may include:

- recent working set
- selected range
- compacted summary
- full raw transcript export

But those are later policy choices, not assumptions this manager should hardcode on day one.

## Data Source Expectations

The manager should continue Pulse's read-only posture toward source data.

### OpenCode

Pulse should read session and message history from the local database structures it already uses for usage derivation, extending the reader to reconstruct transcript content if the underlying message payload supports it.

### Codex

Pulse should read session metadata from local SQLite state and conversation history from local transcript files where available, extending the current transcript reader beyond token-count extraction.

### Consistency rule

The manager should present one normalized Pulse transcript UI while remaining explicit that the underlying storage formats differ by agent.

## Error Handling

The manager must distinguish clearly between:

- no session selected
- transcript still loading
- transcript unavailable
- transcript partially available
- source read failure

Users should never see an ambiguous spinner that could mean either "still working" or "there was nothing here."

If a session's detailed transcript cannot be reconstructed well enough, the UI should say so plainly and keep any available metadata visible.

## Testing

Design verification for implementation should cover:

- `Manage Sessions` entry visibility in all three Agent Usage source modes
- manager window opens and reuses correctly
- theme consistency with existing Pulse windows
- unified and per-agent filtering behavior
- session list population from both OpenCode and Codex sources
- lazy transcript loading on selection
- long-session incremental rendering behavior
- source-native resume action availability
- clear empty, loading, and failure states

Manual verification should include:

- opening the manager from `All`, `OpenCode`, and `Codex`
- browsing mixed-agent session lists
- filtering by project
- selecting long and short sessions
- confirming the transcript area remains responsive
- confirming the window remains visually aligned with Pulse theme behavior

## Scope Notes

- This design does not rely on the deprecated handoff spec for implementation semantics
- This design does not define final `Copy Context` payload rules
- This design does not promise cross-agent continuation in V1
- This design does not change the existing Agent Usage analytics layout
- This design creates the product home for future context export and transcript-based session operations
