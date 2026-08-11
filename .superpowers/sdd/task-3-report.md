# Task 3 Report: Wire Claude Code through AgentSource, repository, and store state

**Branch:** `feat/claude-code-agent-usage`
**Commit:** `edc6b03` — `feat: thread Claude Code source through agent usage store`

## Implementation

Claude Code is now a first-class agent-usage source:

- `pulse/Managers/AgentUsageModels.swift` — `AgentSource.claudeCode` (`"claudecode"`), added to `selectableCases`, `displayName` → "Claude Code", and `AgentUsageDataSourceDescription.message(...)` gained `claudeCodeProjectsURL: URL` + a `.claudeCode` case.
- `pulse/Managers/AgentUsageRepository.swift` — protocol gains `claudeCodeProjectsURL` + `loadClaudeCodeSnapshot()` + `loadClaudeCodeDailyBuckets()`; `AgentUsageRepository` implements them via `ClaudeCodeUsageQuery`.
- `pulse/Managers/AgentUsageViewData.swift` — `AgentUsageLoadedState` gains `claudeCodeSnapshot` / `claudeCodeDailyBuckets` (+ in `.empty`).
- `pulse/Managers/AgentUsageStore.swift` — `RefreshResult` fields, `LoadError.claudeCode(ClaudeCodeUsageQuery.QueryError)`, precomputed dicts `ccBucketsBySession` / `ccMetadataBySession` / `ccSessionsByDirectory`, `init`/`beginRefresh`/`ensureCodexDetailLoaded`/`applyRefreshResult`/`replaceStateForTesting` carry claude state, `loadRefreshResult` loads claude when enabled (error path mirrors codex, `firstError` last-write-wins), `makeAvailableSources` gains `claudeCodeProjectsURL` and includes claude when `FileManager.fileExists` on the projects dir.
- `pulseTests/AgentUsageStoreTests.swift` — `makeClaudeCodeSession` helper + 3 new tests (from brief Step 1); `StubAgentUsageRepository` / `BlockingAgentUsageRepository` extended.
- `pulseTests/AgentUsageViewDataTests.swift` — `StubRepository` conformed to the new protocol; all 15 `AgentUsageLoadedState(...)` call sites updated; `.message(for:)` test call site updated.
- `pulseTests/AgentUsageStoreTests.swift` — 2 `AgentUsageLoadedState(...)` call sites updated (17 total across both files).

## TDD Evidence

**RED** — `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AgentUsageStoreTests`
```
.../AgentUsageStoreTests.swift:933: error: value of type 'StubAgentUsageRepository' has no member 'claudeCodeSnapshot'
...: error: value of type 'AgentUsageLoadedState' has no member 'claudeCodeSnapshot'
...: error: type 'AgentSource' has no member 'claudeCode'
** TEST FAILED **
```

**GREEN (focused)** — same command after implementing:
```
** TEST SUCCEEDED **
53 passed, 0 failed (incl. testRefreshLoadsClaudeCodeState, testAvailableSourcesIncludeClaudeCodeWhenProjectsExist, testAvailableSourcesExcludeClaudeCodeWhenProjectsMissing)
```

**GREEN (full suite):** `xcodebuild test …` → `** TEST SUCCEEDED **` (exit 0)

## Deviations from the brief

1. **`makeAvailableSources` no-source fallback is `[.openCode, .codex]`, NOT `[.openCode, .codex, .claudeCode]`.** The brief's Step 1 test `testAvailableSourcesExcludeClaudeCodeWhenProjectsMissing` sets ALL THREE sources missing (opencode/codex DB paths + claude projects dir) and asserts `.claudeCode` is NOT in `availableSources`. The brief's Step 10 fallback code would put claude there, so the brief contradicts itself — the test fails against the verbatim fallback. I followed the test (the specific behavioral requirement) and left claude out of the empty fallback; this is also more truthful ("claude available iff its directory exists"). Line-779 `setEnabledSources([.codex])` → `[.codex]` still passes.
2. **Compile-forcing placeholder `.claudeCode` cases** added where adding the enum case broke exhaustive switches — Task 4/5 own the real implementations:
   - `AgentUsageStore` derived-data switches (8): `baseSummary` → `state.claudeCodeSnapshot.summary(for: scope)`, `enrichedRequestCount` → `baseSummary.requestCount`, `buildProjectOptions`/`buildSessionOptions`/`buildContextRows`/`buildProviderBreakdown`/`buildModelBreakdownRows` → empty, `latestActivityDate` → `nil`.
   - `AgentUsageView.databasePath` → returns `claudeCodeProjectsURL.path` (needed to compile).
   - `SessionManagementRepository.loadTranscript` (×2) → `[]`, `resumeAction` → `.codex(command: "")` (inert, matches `.all` precedent).
   - `SessionManagementStoreTests` stub `resumeAction` → `.codex(command: "")`.
3. **`SessionManagementStoreTests.testRefreshPublishesPartialSessionListBeforeCompletion` assertion** `loadingSources == [.codex]` → `[.codex, .claudeCode]`. Direct consequence of claude joining `selectableCases` (still-loading sources after an opencode partial = codex + claude). This mirrors the brief's own Step-7 note about 3→4 element lists, which it only applied to the `availableSources` assertion.
4. **`AgentUsageViewDataTests` `.message(for:)` call site updated** with `claudeCodeProjectsURL:` — the brief said the single caller was the view, but the test calls it too (must compile).

## Self-review

- Load/error/availability plumbing mirrors the `.codex` pattern exactly: `beginRefresh` carries claude state, `loadRefreshResult` sets `loadedAnySource` + `firstError` (last-write-wins), `applyRefreshResult`/`replaceStateForTesting` rebuild `ccBucketsBySession`/`ccMetadataBySession`/`ccSessionsByDirectory` as pre-computed dicts — no linear scans introduced (AGENTS.md perf contract intact).
- No subagent filtering for claude (every session is top-level), per the brief.
- All 17 `AgentUsageLoadedState(` call sites in `pulseTests/` updated; verified by `rg -c "claudeCodeSnapshot:"` = 15 + 2.
- Full suite green; focused suite green (53 tests).
- Commit includes the 4 extra files beyond the brief's `git add` list because they are required for the pulse + pulseTests targets to compile (the brief's own Step 2/7 require GREEN).

## Concerns

- The brief's internal contradiction (Step 1 test vs Step 10 fallback) was resolved in favor of the test — worth confirming with the human that claude should be absent from the fresh-install/no-source fallback. If they prefer the fallback to advertise all three sources, the exclusion test must change instead.
- Placeholder derived-data behavior means selecting `.claudeCode` in the UI before Task 4 shows token totals (summary) but empty project/session/breakdown lists; Task 4 replaces all of these.

---

## Fix round 1: availability fallback offers all three sources

**Human decision:** when NO agent sources are detected on disk, the fallback must offer all three: `realSources = [.openCode, .codex, .claudeCode]` (the plan's approved design).

**What changed:**
1. `pulse/Managers/AgentUsageStore.swift` — `makeAvailableSources` empty fallback restored to `[.openCode, .codex, .claudeCode]`.
2. `pulseTests/AgentUsageStoreTests.swift` — `testAvailableSourcesExcludeClaudeCodeWhenProjectsMissing` now uses the "only claude missing" scenario: creates real temporary files for `openCodeDatabaseURL` and `codexDatabaseURL`, points `claudeCodeProjectsURL` at a missing dir, and asserts `.claudeCode` is NOT in `availableSources` (no fallback triggered). `testAvailableSourcesIncludeClaudeCodeWhenProjectsExist` kept as-is.
3. Added `testAvailableSourcesFallbackIncludesClaudeCodeWhenAllSourcesMissing` — all three URLs missing, asserts `availableSources.contains(.claudeCode)` is TRUE (fallback offers all three).

**Test commands + output:**

`xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS'`
```
exit: 0
539: ** TEST SUCCEEDED **
313 passed, 0 failed
Test case 'AgentUsageStoreTests.testAvailableSourcesExcludeClaudeCodeWhenProjectsMissing()' passed
Test case 'AgentUsageStoreTests.testAvailableSourcesFallbackIncludesClaudeCodeWhenAllSourcesMissing()' passed
Test case 'AgentUsageStoreTests.testAvailableSourcesIncludeClaudeCodeWhenProjectsExist()' passed
Test case 'AgentUsageStoreTests.testRefreshLoadsClaudeCodeState()' passed
```

No existing test asserted the old 3-element all-missing fallback list, so no other assertions needed updating.

**Commit:** `fix: availability fallback offers all three sources`
