## What you implemented

- Added a new isolated picker UI in `/Users/zyao/Desktop/pulse/pulse/Views/AgentDateSelectionPicker.swift`.
- Built a compact capsule trigger with calendar and chevron icons, semantic colors, and a popover-based picker flow.
- Added `AgentDateSelectionTriggerLabel` to render concise labels for presets, single-day selections, and ranges.
- Implemented a self-contained popover with preset and custom modes that applies `AgentDateSelection` values back to the caller.
- Integrated the new picker into the `AgentUsageView` header and removed the old standalone segmented range control without changing persistence or refresh behavior.
- Added the new Swift file to the Xcode project.

## What you tested and test results

- `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageViewDataTests`
  - First run failed as expected because `AgentDateSelectionTriggerLabel` did not exist yet.
  - Final run passed.
- `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
  - Passed with `** BUILD SUCCEEDED **`.
- `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
  - Re-run completed with unrelated failing tests:
    - `SessionManagementStoreTests.testLoadTranscriptUsesDiscoveredOpenCodeDatabaseInstance()`
    - `SessionManagementStoreTests.testProjectFilterOptionsDeduplicateProjectsWithinCurrentSource()`

## TDD Evidence

- Added the three trigger-label tests to `AgentUsageViewDataTests` before implementing the new picker UI.
- Ran the focused test target and observed the expected red failure because the trigger label type was missing.
- Implemented the minimal picker and label formatter needed to satisfy the new tests.
- Re-ran the focused test target to green.

## Files changed

- `/Users/zyao/Desktop/pulse/pulse/Views/AgentDateSelectionPicker.swift`
- `/Users/zyao/Desktop/pulse/pulse/Views/AgentUsageView.swift`
- `/Users/zyao/Desktop/pulse/pulse.xcodeproj/project.pbxproj`
- `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageViewDataTests.swift`

## Self-review findings

- The picker logic is isolated to its own file, and `AgentUsageView` only owns the trigger hookup and persistence callback.
- Refresh behavior remains unchanged because the integration only updates persisted date selection through the existing `persistDateSelection` path.
- Semantic colors from `Colors.swift` are used throughout the new UI.
- The new label tests needed corrected fixture day identifiers so they matched the repo’s actual day-bucket encoding.

## Any issues or concerns

- The repository-wide test suite is not fully green at head because two unrelated `SessionManagementStoreTests` fail outside this task’s scope.
- The `pulse.xcodeproj/project.pbxproj` change includes some ordering churn from `ruby add_files.rb`, in addition to the required new file reference.
