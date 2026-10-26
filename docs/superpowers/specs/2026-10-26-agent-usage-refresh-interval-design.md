# Agent Usage Refresh Interval

## Intent

Let users choose how often Agent Usage refreshes automatically, while preserving the current background-refresh behavior. The default remains 30 minutes.

## Goals

- Add an **Auto-refresh** control to **Settings → Agent Usage**.
- Show the control only while **Enable Agent Usage** is on.
- Offer 30 seconds, 1 minute, 10 minutes, 30 minutes, and Custom.
- For Custom, accept a positive whole-number amount and a seconds, minutes, or hours unit.
- Persist the selection across launches and enable/disable changes.
- Apply a changed interval to the active scheduler immediately.

## Non-goals

- Do not add a separate auto-refresh enable/disable toggle; Agent Usage’s existing enable state continues to control scheduled refreshes.
- Do not change manual refresh, refresh-on-panel-open, or refresh-on-tab-entry behavior.
- Do not move refresh scheduling out of `AppDelegate` or change its background lifecycle.

## Approaches

- **Settings → Agent Usage subsection (chosen):** put the interval picker and conditional custom amount/unit controls with the existing Agent Usage preferences. This keeps the setting discoverable alongside the feature it controls.
- **General settings or a new settings page (not chosen):** these would separate the preference from Agent Usage or add unnecessary navigation.
- **Control in the Agent Usage panel (not chosen):** this would put the setting outside the Settings window, contrary to the requested location.

## Behavior and constraints

- Store the selected preset or custom duration in the existing Agent Usage preferences (`UserDefaults`), with 30 minutes used when no saved value exists.
- When Agent Usage is enabled, the existing repeating background scheduler uses the configured duration, including while the panel is closed. When disabled, the scheduler remains cancelled and the Auto-refresh controls are hidden.
- Changing the interval while enabled replaces the current schedule with one using the new interval; it does not trigger an immediate refresh.
- Retain the project’s existing SwiftUI settings patterns and resizable Settings window. Do not add a fixed outer frame that conflicts with its 520×280 minimum.
- Keep custom input valid and positive before applying it; invalid or incomplete input must not create a zero/invalid timer interval.

## Implementation scope

Update the Agent Usage preference model, its Settings section, and the `AppDelegate` scheduler so the stored interval is read and can be changed while the scheduler is active. Add focused tests for preference defaults/persistence and scheduler reconfiguration behavior.
