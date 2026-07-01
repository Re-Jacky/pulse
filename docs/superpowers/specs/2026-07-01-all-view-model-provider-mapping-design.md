# All-View Provider/Model Mapping Design

## Goal

Allow users to merge and rename provider/model identities in the combined `All` Agent Usage view without changing source-native identities in per-agent views.

## Problem

The combined `All` view currently aggregates provider/model usage using raw source-native names. Equivalent models can appear fragmented when different agents report different provider IDs or model names for the same underlying model, such as:

- `codex-gpt / gpt-5.4`
- `custom / gpt-5.4`

Users need a safe way to unify those entries for the combined view without losing source-native fidelity elsewhere.

## Scope

This feature applies only to the combined `All` view.

- The `All` view provider/model breakdown cards will support user-defined mapping.
- Per-agent views (`OpenCode`, `Codex`) remain unchanged and continue to show raw source-native identities.
- Existing token, session, and project data sources remain unchanged.

## UX

### Breakdown Cards

The combined `All` view keeps the existing provider and model breakdown card design.

- A small gear icon appears in the header of the provider breakdown card when `source == .all`.
- A small gear icon appears in the header of the model breakdown card when `source == .all`.
- These controls are hidden for per-agent views.

### Mapping Panel

Clicking the gear opens a lightweight mapping panel.

The panel contains two sections or tabs:

- `Providers`
- `Models`

Each row shows:

- raw source (`Codex`, `OpenCode`, or future agent source)
- raw provider/model identifier or display label
- current mapped display name

Supported actions:

- assign a custom display name
- map multiple raw entries to the same display name
- reset a mapping back to default/raw behavior

The panel should make clear that mappings affect only the combined `All` view.

## Data Model

### Raw Identity

Mappings should be keyed by raw identity, including source, to avoid accidental collisions.

Provider raw identity should include:

- source
- raw provider ID and/or raw provider display name

Model raw identity should include:

- source
- raw provider ID/name context
- raw model ID and/or raw model display name

### Canonical Display Layer

Mappings resolve raw identities into user-facing canonical display names:

- `displayProviderName`
- `displayModelName`

These names are only used for grouping and display in the combined `All` view.

### Persistence

Mappings should be persisted locally in app settings storage.

Initial implementation can use a lightweight persisted store similar to other app preferences. The store should support:

- load all mappings
- upsert one mapping
- delete/reset one mapping

## Resolution Rules

When rendering combined `All` provider/model breakdowns:

1. Check for a user-defined mapping.
2. If none exists, optionally apply built-in alias defaults.
3. If still unresolved, use the raw source-native display name.

User-defined mappings always win over defaults.

## Aggregation Behavior

### Provider Breakdown

For the combined `All` provider breakdown:

- normalize each raw provider identity into a display provider name
- merge summaries for entries that resolve to the same display provider name

### Model Breakdown

For the combined `All` model breakdown:

- normalize each raw model identity into a display model name
- merge summaries for entries that resolve to the same display model name

Single-agent breakdown logic remains unchanged.

## Implementation Boundaries

The normalization layer should sit on top of existing raw usage data.

- Do not mutate source-native session/model/provider data.
- Do not change the daily bucket storage format.
- Do not change per-agent summary paths.
- Restrict the normalization pass to the combined provider/model breakdown paths.

## Error Handling

- Unknown/unmapped entries remain separate rather than being auto-merged.
- Resetting a mapping immediately falls back to default/raw rendering.
- Corrupt or missing persisted mapping data should fail safely by showing raw names.

## Testing

Add coverage for:

- combined provider breakdown merges mapped aliases
- combined model breakdown merges mapped aliases
- unmapped entries remain separate
- per-agent views ignore combined-view mappings
- reset behavior restores raw grouping
- persisted mappings reload correctly

## Rollout Notes

Start with a manual mapping UI only.

Possible later enhancements:

- suggested mappings for near-duplicate names
- bulk merge workflows
- import/export mapping profiles
