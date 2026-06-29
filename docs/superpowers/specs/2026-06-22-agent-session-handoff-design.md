# Agent Session Handoff Design

Date: 2026-06-22
Status: Deprecated

Deprecated note: This design is no longer considered an acceptable implementation plan. It is preserved only as historical context and should not be used to drive feature work. Conversation history, copy-context behavior, cross-agent migration semantics, and edge-case handling need further product and technical design before implementation.

## Summary

Pulse will add a V1 session handoff feature that lets users export a selected agent session into a Pulse-owned portable bundle, then continue that work in another enabled agent through a target-specific command that can be copied from the UI.

This design also refines Agent Usage settings so users explicitly choose which supported agents participate in the Agent panel and in aggregate calculations. In V1, the supported agents are OpenCode and Codex, and both are enabled by default for existing and new users.

The handoff flow is intentionally CLI-first. Pulse does not try to launch the target agent automatically and does not attempt a fragile deep import into Codex-native storage. Instead, Pulse owns the bundle format and generates the correct continuation command per target.

## Goals

- Let users continue a selected session in another enabled agent without manually reconstructing task context.
- Keep the feature honest about what each agent actually supports today.
- Make source and target availability consistent with Agent Usage settings.
- Preserve a clear user-visible indication that a continued session originated from Pulse.
- Store Pulse handoff artifacts in a predictable app-owned location and allow clearing them from Settings.

## Non-Goals

- Launching the target CLI from Pulse.
- Writing directly into Codex internal storage formats as the primary V1 path.
- Supporting agents other than OpenCode and Codex in V1.
- Building a full history browser for exported Pulse bundles.
- Replacing the existing agent usage readers with a write-capable shared storage layer.

## Current Context

Pulse currently treats agent data as read-only:

- OpenCode usage metadata comes from `opencode.db`.
- Codex usage metadata comes from the union of valid `state_*.sqlite` files plus transcript `.jsonl` files under `~/.codex`.
- The Agent panel already supports source, project, and session selection.
- Settings currently expose a single `Enable Agent Usage` toggle.

This means the best V1 feature is not "native migration" but a Pulse-owned handoff layer built on top of the existing session selection UI.

## User Experience

### Settings

The `Settings > Agent Usage` section will contain:

- `Enable Agent Usage` toggle
- A supported-agent selection list for `OpenCode` and `Codex`
- A `Clear Pulse Handoff Data` button

Behavior:

- New users default to Agent Usage enabled state unchanged from current product behavior.
- Supported-agent selection defaults to both `OpenCode` and `Codex` enabled.
- Existing users are migrated so both supported agents start enabled.
- If `Enable Agent Usage` is off, the Agent tab remains hidden entirely.
- If `Enable Agent Usage` is on, only selected agents appear in the Agent panel.
- Aggregate values for `All` only include selected agents.
- The selected agents also define valid handoff sources and targets.
- `Clear Pulse Handoff Data` removes all Pulse-managed handoff artifacts from `~/.pulse`.

### Agent panel visibility

The Agent panel continues to use the existing source picker pattern, but its available sources are filtered by settings:

- If both OpenCode and Codex are selected, source options behave as today: `OpenCode`, `Codex`, and `All`.
- If only one agent is selected, only that single source is shown and `All` is omitted because it adds no value.
- If no agents are selected while Agent Usage is enabled, the panel should show an empty-state message explaining that the user needs to enable at least one agent in Settings.

### Export / Continue in...

When a concrete session is selected in the Agent panel, Pulse shows an `Export / Continue in...` action.

Clicking it opens a compact chooser surface that:

- Lists only enabled target agents
- Excludes impossible or meaningless options
- Shows a short target-specific explanation
- Shows one or more generated continuation options depending on the target
- Provides a `Copy` button for each command or prompt option

Pulse creates or refreshes the bundle before presenting the command so the copied command always points at a valid current artifact.

### Continued-session naming

Every session continued from a Pulse bundle must have a notable title or name indicating that Pulse supported the handoff.

V1 requirement:

- The generated continuation prompt or import metadata must cause the target session to use a visibly Pulse-attributed title when possible.
- Recommended title prefix: `Pulse: `

Examples:

- `Pulse: Fix updater packaging regression`
- `Pulse: Continue pulse menu bar debugging`

If a target cannot set the title directly at creation time, the generated prompt must instruct the target agent to use a Pulse-attributed session title in its first turn context.

## Supported V1 flows

The valid source and target set is the enabled agent set from Settings.

V1 officially supports:

- OpenCode -> Codex
- Codex -> OpenCode
- OpenCode -> OpenCode
- Codex -> Codex

Support here means Pulse can generate a bundle and a target-specific continuation command. It does not guarantee identical fidelity across agents.

Expected fidelity:

- OpenCode -> OpenCode: highest
- Codex -> Codex: medium, because the V1 path is still Pulse-bundle driven rather than native thread cloning
- Cross-agent flows: medium to low, but intentionally useful rather than structurally complete

## Pulse bundle format

Pulse will create a managed home directory at `~/.pulse`.

V1 directory layout:

- `~/.pulse/handoffs/`
- `~/.pulse/handoffs/<bundle-id>/bundle.json`
- `~/.pulse/handoffs/<bundle-id>/prompt.txt`

Optional future files may be added under the same bundle directory, but V1 only requires the canonical JSON bundle plus a generated prompt file.

### Bundle contents

The Pulse bundle is a normalized, Pulse-owned format. It is not a copy of OpenCode export JSON and not a copy of Codex internal storage.

Required fields:

- bundle id
- exported at timestamp
- Pulse version
- source agent
- source session id
- source session title
- source project directory
- source model summary
- source creation/update timestamps
- normalized session summary
- normalized transcript payload available in V1
- goals and subagent summary when available
- recommended continued-session title with Pulse attribution
- target guidance metadata

The `prompt.txt` file contains a target-ready continuation prompt derived from the bundle.

### Transcript normalization

V1 should normalize enough data to preserve user intent and recent working context without overcommitting to perfect structural parity.

Recommended normalization priority:

1. Session title and project path
2. Latest task summary
3. Recent user and assistant exchange summary
4. Goals and subagent relationships when available
5. Full transcript excerpts only where the source format is easy and stable enough

For Codex, this likely comes from transcript `.jsonl` parsing plus thread metadata. For OpenCode, this may come from native export JSON if Pulse decides to leverage the CLI later, or from direct DB-backed reconstruction where feasible.

## Target-specific continuation behavior

Pulse must generate different commands for different targets.

### Continue in OpenCode

OpenCode already supports import-oriented workflows, so the generated UI should expose two copy options.

Option 1: native import command

V1 command shape:

```bash
opencode import ~/.pulse/handoffs/<bundle-id>/bundle.json
```

If OpenCode import requires a target-compatible transformed JSON rather than the canonical Pulse bundle, Pulse may write an additional derived file under the same bundle directory and point the command at that derived file instead.

Option 2: reusable prompt for an existing OpenCode session

Pulse also writes a target-ready prompt that can be pasted into an already-running or resumed OpenCode session when the user does not want to create a new imported session.

The UI should therefore provide:

- `Copy Import Command`
- `Copy Prompt`

Requirement:

- The imported OpenCode session must use the Pulse-attributed title from the bundle.
- The OpenCode prompt must explicitly instruct the receiving session to continue under the Pulse-attributed title from the bundle.

### Continue in Codex

Codex does not expose an equivalent stable `import session.json` CLI path, so V1 uses a continuation command that starts or resumes a Codex session with the Pulse-generated prompt.

V1 command shape should be Codex-specific and copyable, for example:

```bash
codex "$(cat ~/.pulse/handoffs/<bundle-id>/prompt.txt)"
```

If implementation learns that a more robust Codex command form is preferable, the exact shell form may change, but the product behavior remains:

- Pulse writes a bundle
- Pulse writes a Codex-ready continuation prompt
- Pulse shows a `Copy` button for the resulting Codex command
- Pulse may also expose a direct `Copy Prompt` option if implementation determines that pasting into an existing Codex session is reliable enough, but this is not required for V1

Requirement:

- The prompt must explicitly instruct Codex to continue under the Pulse-attributed session title from the bundle.

## Target filtering rules

The target list shown in `Export / Continue in...` follows these rules:

- Only selected agents from Settings can appear.
- A session from one source agent can target any selected agent, including the same agent.
- If only one agent is selected, the target list contains only that agent.
- If no targets are available, the action should be disabled and explain why.

## Data model changes

### Agent usage settings

Replace the current boolean-only mental model with:

- top-level `isEnabled`
- per-agent enabled set

Suggested persisted keys:

- `agentUsageEnabled`
- `agentUsageEnabledSources`

Migration:

- If `agentUsageEnabledSources` is absent, initialize it to `[OpenCode, Codex]`.

### New handoff models

Add focused models for:

- `PulseHandoffBundle`
- `PulseHandoffSource`
- `PulseHandoffTarget`
- `PulseHandoffTranscriptEntry`
- `PulseHandoffCommand`

These should stay separate from existing usage snapshot types so the read-only metrics pipeline does not absorb export responsibilities.

## New components

### `PulseHandoffStore`

Responsibilities:

- Ensure `~/.pulse` and `~/.pulse/handoffs` exist
- Create bundle directories
- Write `bundle.json`
- Write `prompt.txt`
- Clear stored handoff data from Settings

### `PulseHandoffBuilder`

Responsibilities:

- Convert a selected agent session into a normalized `PulseHandoffBundle`
- Pull data from the appropriate source-specific repository/query path
- Produce a recommended Pulse-attributed session title

### `AgentContinuationCommandBuilder`

Responsibilities:

- Build target-specific commands from a handoff bundle
- Keep shell output deterministic and copy-safe
- Provide the display string used by the UI `Copy` button

### Settings integration

Settings becomes the source of truth for:

- whether Agent Usage exists in the UI
- which agents participate in calculations
- which agents are valid export targets

## Error handling

Settings:

- If `Clear Pulse Handoff Data` fails, show a visible error and leave existing data untouched.

Bundle creation:

- If Pulse cannot read enough session data to build a valid bundle, the export flow should fail with a clear source-specific message.
- If a source has partial data, Pulse may still create a reduced bundle as long as the continuation prompt remains useful.

Command generation:

- If a target command cannot be generated, the target should be omitted or shown disabled with a concise explanation.

Filesystem:

- Missing `~/.pulse` should be treated as normal and created on demand.
- Corrupt existing bundle directories should not block creation of a new bundle.

## Testing

### Unit tests

- Settings migration defaults both agents to enabled
- Per-agent selection changes `availableSources`
- `All` calculations include only enabled agents
- Single-agent selection hides unnecessary `All`
- Handoff bundle serialization and deserialization
- Pulse-attributed session title generation
- OpenCode command generation
- Codex command generation
- Clear handoff data deletes only Pulse-managed handoff artifacts

### Integration-focused tests

- Creating a handoff from an OpenCode session
- Creating a handoff from a Codex session
- Disabled agents do not appear as targets
- Export action unavailable when no concrete session is selected

## Rollout notes

This design intentionally favors clarity over maximum automation:

- Users select their active agents in Settings.
- Pulse owns the portable session bundle.
- Pulse generates the right continuation command per target.
- Users copy and run that command themselves.

That gives immediate cross-agent usefulness while staying aligned with what OpenCode and Codex actually support today.

## Open questions resolved in this spec

- Which agents count in usage and appear as export targets?
  Answer: only the agents selected in `Settings > Agent Usage`.

- What is the default selected-agent behavior after upgrade?
  Answer: OpenCode and Codex both start enabled by default.

- Where are Pulse handoff artifacts stored?
  Answer: under `~/.pulse`.

- Should Pulse launch the target CLI automatically?
  Answer: no.

- How should continued sessions be identified?
  Answer: with a notable Pulse-attributed title, preferably using the `Pulse: ` prefix.
