# Task 6 Report

## Scope

Implemented Task 6 only within the approved session-management files and tests:

- `pulse/Managers/SessionManagementStore.swift`
- `pulse/Views/SessionListSidebarView.swift`
- `pulse/Views/SessionTranscriptDetailView.swift`
- `pulseTests/SessionManagementStoreTests.swift`
- `pulseTests/OpenCodeSessionTranscriptTests.swift`
- `pulseTests/CodexSessionTranscriptTests.swift`

`pulse/Managers/SessionManagementRepository.swift` was reviewed but did not require changes because source-native resume command generation was already correct for OpenCode and Codex.

## What Changed

### Project filtering

- Added `SessionProjectOption` in `SessionManagementStore`
- Derived `projectOptions` from loaded sessions during `refreshIfNeeded()`
- Kept option identity keyed by `projectPath`
- Preserved existing in-memory filtering via `selectedProjectPath`
- Added a `Project` picker to `SessionListSidebarView` with:
  - `All Projects`
  - one option per derived project

### Source-native resume actions

- Added `selectedResumeAction` to `SessionManagementStore`
- Wired the selected session to repository-provided `ResumeAction`
- Reused existing source-native repository behavior:
  - OpenCode -> `opencode resume <rawSessionID>`
  - Codex -> `codex resume <rawSessionID>`

### Placeholder action surface

- Added a right-pane action bar in `SessionTranscriptDetailView`
- Included:
  - `Copy Resume Command`
  - `Copy Context`
  - `More Actions`
- Implemented pasteboard copy only for the resume command
- Kept `Copy Context` and `More Actions` as intentional placeholders, per brief

## Tests Added

### `pulseTests/SessionManagementStoreTests.swift`

- `testProjectFilterOptionsAreDerivedFromLoadedSessions`
- `testResumeActionTracksSelectedSessionSource`

### `pulseTests/OpenCodeSessionTranscriptTests.swift`

- `testOpenCodeResumeActionUsesSourceNativeCommand`

### `pulseTests/CodexSessionTranscriptTests.swift`

- `testCodexResumeActionUsesSourceNativeCommand`

## TDD Record

### Red

Ran:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests
```

Observed expected failure:

- `SessionManagementStore` had no member `projectOptions`
- `SessionManagementStore` had no member `selectedResumeAction`

### Green

Re-ran:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/SessionManagementStoreTests
```

Result:

- `** TEST SUCCEEDED **`

## Full Verification

Ran exactly as required by the brief.

### 1. Full test suite

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
```

Result:

- `** TEST SUCCEEDED **`

### 2. Debug build

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Result:

- `** BUILD SUCCEEDED **`

## Self-Review

### Spec coverage

- Project filter options are now derived from loaded sessions and exposed in the sidebar
- Resume action now tracks the selected session source and remains source-native only
- Right-pane action area now exists for resume plus placeholder `Copy Context` / future actions
- No cross-agent continuation was introduced
- `Copy Context` remains a placeholder surface only

### Placeholder scan

- Only intentional placeholders remain:
  - `Copy Context`
  - `More Actions`

### Scope check

- No unrelated files were changed
- No existing unrelated edits were reverted

## Commit

Created one commit for Task 6 after verification.

## Follow-Up: Source-Aware Project Picker

Addressed the remaining Task 6 review finding that the project picker must track the active source pivot.

### Problem

- `projectOptions` was originally derived once from all loaded sessions
- Switching `selectedSourceFilter` to `OpenCode` or `Codex` could still show projects that only existed in the other source
- Selecting one of those projects could leave the list empty in a confusing way

### Fix

- Made `projectOptions` source-aware by deriving them from the current `selectedSourceFilter`
- Added source-filter observers in `SessionManagementStore` so project options refresh whenever the active source pivot changes
- Normalized `selectedProjectPath` whenever the source pivot changes so stale project selections are cleared if they are no longer valid for the current source
- Kept behavior scoped to the existing store/project-filter surface only

### Additional Tests

Added store coverage for the combined source-filter + project-filter behavior:

- `testProjectFilterOptionsFollowActiveSourcePivot`
- `testVisibleSessionsClearsStaleProjectSelectionWhenSourcePivotChanges`

### Follow-Up Verification

Re-ran the required commands after this fix:

```bash
xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Results recorded after the follow-up implementation:

- `** TEST SUCCEEDED **`
- `** BUILD SUCCEEDED **`
