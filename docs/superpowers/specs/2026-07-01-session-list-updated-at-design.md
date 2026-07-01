# Session List Updated Timestamp Design

## Summary

Add a compact last-updated timestamp to each session row in the session manager sidebar so users can quickly tell why a session appears near the top of the list.

The session list already sorts by `updatedAt` descending. This change improves visibility, not ordering behavior.

## Goals

- Make recency visible in the session list without adding new controls.
- Preserve the current compact sidebar density.
- Reuse an existing short date/time formatting style used elsewhere in the app.

## Non-Goals

- Changing session ordering behavior.
- Adding user-configurable sorting.
- Adding a new line or expanding row height substantially.
- Changing session repository or store loading logic.

## Proposed UI

Each session row will continue to show:

- Title
- Project name
- Metadata line

The metadata line will be updated from:

- `<source/model subtitle>`

to:

- `<source/model subtitle> • <short updated timestamp>`

Example:

- `openai / gpt-5.4 • Jul 1, 14:32`

This keeps the current three-line structure and makes the reason for the list order immediately visible.

## Formatting

Use a compact absolute timestamp rather than a relative label like `2h ago`.

Reasoning:

- Absolute times are clearer and more stable in a sidebar that may stay open.
- The app already uses short date/time formatting patterns elsewhere, so this is the most consistent choice.
- It avoids churn from relative text changing while the view remains mounted.

The timestamp formatter should follow the existing short-date-time style already used in agent usage details.

## Implementation Scope

This change should stay view-local.

Data is already available via `ManagedSessionSummary.updatedAt`, so no repository, model, or store shape changes should be required.

Expected implementation area:

- `pulse/Views/SessionListSidebarView.swift`

Possible helper:

- Small local formatter/helper for the compact timestamp string

## Testing

Add focused coverage for the new row metadata formatting if there is a practical seam.

Preferred options:

- A small helper-level test for the timestamp metadata string, if extracted cleanly
- Otherwise, minimal targeted coverage around the formatting helper without introducing heavyweight view testing

Manual verification should confirm:

- Rows still render at the expected density
- Long model subtitles still truncate cleanly
- Timestamp appears for both OpenCode and Codex sessions
- Newest sessions remain visually understandable at a glance

## Risks

- Metadata line may become too long for narrower sidebar widths.
- Reusing a formatter inconsistently could introduce a subtly different timestamp style than nearby app surfaces.

## Mitigations

- Keep the timestamp compact and on the existing subtitle line.
- Preserve current `.lineLimit(1)` truncation behavior on the metadata line.
- Reuse an established formatting pattern instead of inventing a new one.
