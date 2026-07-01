What you implemented
- Refactored `AgentUsageStore` derivation to resolve `AgentDateSelection` into day intervals and use those intervals across in-memory aggregation, latest-activity lookup, request counting, token-flow, and OpenCode breakdown helpers.
- Preserved refresh behavior by keeping SQL/database access in the existing refresh/load path only; date selection changes remain purely in-memory.
- Added `AgentDateSelection.preset` as a small compatibility helper and updated `reconcile` to preserve explicit date selections without touching the legacy `timeRange` compatibility accessor.
- Added a DEBUG-only refresh-generation test seam and new store tests covering explicit single-day filtering, inclusive day-range filtering, and no refresh-generation mutation during derivation.
- Added snapshot-based interval fallback for explicit selections when a source has no daily buckets, which preserves mixed-source token-flow behavior.

What you tested and test results
- Ran focused Task 2 coverage:
  - `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/AgentUsageViewDataTests`
  - Result: PASS
- Ran full suite verification:
  - `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
  - Result: FAIL, but only in unrelated tests:
    - `SessionManagementStoreTests.testLoadTranscriptUsesDiscoveredOpenCodeDatabaseInstance()`
    - `SessionManagementStoreTests.testProjectFilterOptionsDeduplicateProjectsWithinCurrentSource()`
- All agent-usage tests, including the new Task 2 coverage, passed in the full-suite run.

TDD Evidence
- Added the new explicit-date derivation tests first in `pulseTests/AgentUsageStoreTests.swift`.
- Ran the focused test command and observed RED with the three new tests failing:
  - `testDerivedDataForSingleDayUsesOnlyBucketsInThatDay`
  - `testDerivedDataForRangeUsesInclusiveEndpoints`
  - `testDateSelectionDoesNotChangeRefreshGeneration`
- Implemented the minimal interval-based store refactor plus the DEBUG test hook.
- Re-ran the focused test command until GREEN.
- Fixed one regression caught by an existing focused test (`testDerivedDataForAllSourceTokenFlowFallsBackPerSourceWhenOnlyOneHasBuckets`) before proceeding to final verification.

Files changed
- `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageStore.swift`
- `/Users/zyao/Desktop/pulse/pulse/Managers/AgentUsageModels.swift`
- `/Users/zyao/Desktop/pulse/pulseTests/AgentUsageStoreTests.swift`

Self-review findings
- The store now avoids calling `selection.timeRange` from derivation paths that may receive explicit `singleDay` or `dayRange` selections, preventing compatibility crashes introduced by the new selection model.
- Explicit-date fallback without daily buckets now filters already-loaded snapshots by local-calendar day identifiers, which keeps date changes in-memory and restores mixed-source token-flow behavior.
- I did not need to modify `pulseTests/AgentUsageViewDataTests.swift`; existing coverage there already exercised the affected token-flow fallback path and caught the only regression from the refactor.

Any issues or concerns
- Full-suite verification is not fully green because two `SessionManagementStoreTests` fail outside this task’s ownership and outside the changed files.
- Because those failures are unrelated, I committed the scoped Task 2 work but am reporting the suite status as done with concerns.

Review follow-up fix
- Fixed the OpenCode explicit-date no-buckets fallback so provider and model breakdowns use the already-filtered in-memory `OpenCodeUsageSnapshot` when `state.openCodeDailyBuckets.isEmpty`.
- Added a regression test covering explicit single-day OpenCode breakdowns without daily buckets.

Follow-up verification
- Ran: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests -only-testing:pulseTests/AgentUsageViewDataTests`
- Result: PASS
- New regression covered:
  - `AgentUsageViewDataTests.testDerivedDataForOpenCodeExplicitDateWithoutBucketsUsesSnapshotBreakdowns()`
