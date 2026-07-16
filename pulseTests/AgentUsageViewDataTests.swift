import XCTest
@testable import Pulse

final class AgentUsageViewDataTests: XCTestCase {
    func testTokenActivityDefaultMonthUsesCurrentMonthWhenItHasActivity() {
        let calendar = Calendar.gregorianUTCForTests
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13))!
        let currentMonthDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
        let olderDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30))!

        let month = AgentUsageActivityCalendarLayout.displayMonth(
            for: [
                TokenUsageDataPoint(date: olderDate, totalTokens: 10, bucketSizeDays: 1),
                TokenUsageDataPoint(date: currentMonthDate, totalTokens: 20, bucketSizeDays: 1)
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(month.year, 2026)
        XCTAssertEqual(month.month, 7)
    }

    func testTokenActivityDefaultMonthUsesCurrentMonthWhenActivityIsOlder() {
        let calendar = Calendar.gregorianUTCForTests
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13))!
        let latestDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 18))!
        let olderDate = calendar.date(from: DateComponents(year: 2025, month: 12, day: 20))!

        let month = AgentUsageActivityCalendarLayout.displayMonth(
            for: [
                TokenUsageDataPoint(date: olderDate, totalTokens: 10, bucketSizeDays: 1),
                TokenUsageDataPoint(date: latestDate, totalTokens: 20, bucketSizeDays: 1)
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(month.year, 2026)
        XCTAssertEqual(month.month, 7)
    }

    func testTokenActivityDefaultYearUsesCurrentYearWhenActivityIsOlder() {
        let calendar = Calendar.gregorianUTCForTests
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13))!
        let olderDate = calendar.date(from: DateComponents(year: 2025, month: 12, day: 20))!

        let year = AgentUsageActivityCalendarLayout.displayYear(
            for: [TokenUsageDataPoint(date: olderDate, totalTokens: 10, bucketSizeDays: 1)],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(year, 2026)
    }

    func testTokenActivityMonthCellsUseNaturalCalendarPadding() {
        let calendar = Calendar.gregorianUTCForTests
        let month = AgentUsageActivityDisplayMonth(year: 2026, month: 7)
        let cells = AgentUsageActivityCalendarLayout.monthCells(for: month, calendar: calendar)

        XCTAssertEqual(cells.count, 35)
        XCTAssertFalse(cells[0].isInDisplayedMonth)
        XCTAssertEqual(calendar.component(.day, from: cells[0].date), 28)
        XCTAssertTrue(cells[3].isInDisplayedMonth)
        XCTAssertEqual(calendar.component(.day, from: cells[3].date), 1)
        XCTAssertTrue(cells[33].isInDisplayedMonth)
        XCTAssertEqual(calendar.component(.day, from: cells[33].date), 31)
        XCTAssertFalse(cells[34].isInDisplayedMonth)
    }

    func testTokenActivityWeekdayLabelsUseThreeLetterNames() {
        var calendar = Calendar.gregorianUTCForTests
        calendar.firstWeekday = 2

        XCTAssertEqual(
            AgentUsageActivityCalendarLayout.weekdayLabels(calendar: calendar),
            ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        )
    }

    func testTokenActivityDisplayMonthCanMoveForwardAndBackward() {
        XCTAssertEqual(
            AgentUsageActivityCalendarLayout.month(byAdding: -1, to: AgentUsageActivityDisplayMonth(year: 2026, month: 1)),
            AgentUsageActivityDisplayMonth(year: 2025, month: 12)
        )
        XCTAssertEqual(
            AgentUsageActivityCalendarLayout.month(byAdding: 1, to: AgentUsageActivityDisplayMonth(year: 2026, month: 12)),
            AgentUsageActivityDisplayMonth(year: 2027, month: 1)
        )
    }

    func testTokenActivityCurrentPeriodUsesProvidedLocalCalendarDate() {
        let calendar = Calendar.gregorianUTCForTests
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16))!

        XCTAssertEqual(
            AgentUsageActivityCalendarLayout.currentDisplayMonth(now: now, calendar: calendar),
            AgentUsageActivityDisplayMonth(year: 2026, month: 7)
        )
        XCTAssertEqual(
            AgentUsageActivityCalendarLayout.currentDisplayYear(now: now, calendar: calendar),
            2026
        )
    }

    func testTokenActivityYearSummaryUsesTwelveMonthlyBuckets() {
        let calendar = Calendar.gregorianUTCForTests
        let months = AgentUsageActivityCalendarLayout.yearMonths(for: 2026, calendar: calendar)

        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.first, AgentUsageActivityDisplayMonth(year: 2026, month: 1))
        XCTAssertEqual(months.last, AgentUsageActivityDisplayMonth(year: 2026, month: 12))
    }

    func testTokenActivityPaletteUsesReadableLightAndDarkRamps() {
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 0, maxTokens: 100), .none)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 1, maxTokens: 200_000_000), .lowest)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 30_000_000, maxTokens: 200_000_000), .low)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 60_000_000, maxTokens: 200_000_000), .mediumLow)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 100_000_000, maxTokens: 200_000_000), .medium)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 130_000_000, maxTokens: 200_000_000), .mediumHigh)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 170_000_000, maxTokens: 200_000_000), .high)
        XCTAssertEqual(AgentUsageActivityColorPalette.level(for: 200_000_000, maxTokens: 200_000_000), .highest)

        XCTAssertEqual(
            AgentUsageActivityColorPalette.activeLevels.count,
            7
        )
        XCTAssertEqual(
            Set(AgentUsageActivityColorPalette.activeLevels.compactMap {
                AgentUsageActivityColorPalette.fillHex(for: $0, colorScheme: .light)
            }).count,
            7
        )
        XCTAssertEqual(
            Set(AgentUsageActivityColorPalette.activeLevels.compactMap {
                AgentUsageActivityColorPalette.fillHex(for: $0, colorScheme: .dark)
            }).count,
            7
        )
        XCTAssertEqual(
            AgentUsageActivityColorPalette.fillHex(for: .lowest, colorScheme: .light),
            "#E0F7F4"
        )
        XCTAssertEqual(
            AgentUsageActivityColorPalette.fillHex(for: .highest, colorScheme: .light),
            "#065F73"
        )
        XCTAssertEqual(
            AgentUsageActivityColorPalette.fillHex(for: .lowest, colorScheme: .dark),
            "#203A52"
        )
        XCTAssertEqual(
            AgentUsageActivityColorPalette.fillHex(for: .highest, colorScheme: .dark),
            "#D6F4FF"
        )
    }

    func testTokenActivityFiltersDailyTrendDataToDisplayMonth() {
        let calendar = Calendar.gregorianUTCForTests
        let juneDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        let julyDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let augustDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!

        let filtered = AgentUsageActivityCalendarLayout.filteredDataPoints(
            [
                TokenUsageDataPoint(date: juneDate, totalTokens: 10, bucketSizeDays: 1),
                TokenUsageDataPoint(date: julyDate, totalTokens: 20, bucketSizeDays: 1),
                TokenUsageDataPoint(date: augustDate, totalTokens: 30, bucketSizeDays: 1)
            ],
            scope: .month,
            displayMonth: AgentUsageActivityDisplayMonth(year: 2026, month: 7),
            displayYear: 2026,
            calendar: calendar
        )

        XCTAssertEqual(filtered.map(\.totalTokens), [20])
    }

    func testTokenActivityFiltersDailyTrendDataToDisplayYear() {
        let calendar = Calendar.gregorianUTCForTests
        let previousYearDate = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!
        let firstDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let secondDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        let filtered = AgentUsageActivityCalendarLayout.filteredDataPoints(
            [
                TokenUsageDataPoint(date: previousYearDate, totalTokens: 10, bucketSizeDays: 1),
                TokenUsageDataPoint(date: firstDate, totalTokens: 20, bucketSizeDays: 1),
                TokenUsageDataPoint(date: secondDate, totalTokens: 30, bucketSizeDays: 1)
            ],
            scope: .year,
            displayMonth: AgentUsageActivityDisplayMonth(year: 2026, month: 1),
            displayYear: 2026,
            calendar: calendar
        )

        XCTAssertEqual(filtered.map(\.totalTokens), [20, 30])
    }

    func testDateSelectionSummaryLabelForPresetToday() {
        XCTAssertEqual(
            AgentDateSelectionTriggerLabel.text(for: .preset(.today), calendar: .gregorianUTCForTests),
            "Today"
        )
    }

    func testDateSelectionSummaryLabelForSingleDayUsesFormattedDate() {
        XCTAssertEqual(
            AgentDateSelectionTriggerLabel.text(for: .singleDay(19_909), calendar: .gregorianUTCForTests),
            "Jul 5, 2024"
        )
    }

    func testDateSelectionSummaryLabelForRangeUsesBothDates() {
        XCTAssertEqual(
            AgentDateSelectionTriggerLabel.text(
                for: .dayRange(startDay: 19_909, endDay: 19_911),
                calendar: .gregorianUTCForTests
            ),
            "Jul 5 - Jul 7"
        )
    }

    func testDateSelectionSummaryLabelForSingleDayUsesLocalCalendarWhenReconstructingStoredDay() {
        XCTAssertEqual(
            AgentDateSelectionTriggerLabel.text(
                for: .singleDay(19_909),
                calendar: .gregorianPacificForTests
            ),
            "Jul 5, 2024"
        )
    }

    func testDateSelectionSummaryLabelForRangeUsesLocalCalendarWhenReconstructingStoredDays() {
        XCTAssertEqual(
            AgentDateSelectionTriggerLabel.text(
                for: .dayRange(startDay: 19_909, endDay: 19_911),
                calendar: .gregorianPacificForTests
            ),
            "Jul 5 - Jul 7"
        )
    }

    func testCalendarDatesForLast7DaysPresetExpandToConcreteLocalRange() {
        let now = Date(timeIntervalSince1970: 1_720_558_400)
        let dates = agentDateSelectionCalendarDates(
            for: .preset(.last7Days),
            calendar: .gregorianUTCForTests,
            now: now
        )

        XCTAssertEqual(
            agentUsageDayIdentifier(for: dates.startDate, calendar: .gregorianUTCForTests),
            19_907
        )
        XCTAssertEqual(
            agentUsageDayIdentifier(for: dates.endDate, calendar: .gregorianUTCForTests),
            19_913
        )
    }

    func testCalendarDatesForYesterdayPresetExpandToPreviousLocalDay() {
        let now = Date(timeIntervalSince1970: 1_720_558_400)
        let dates = agentDateSelectionCalendarDates(
            for: .preset(.today),
            calendar: .gregorianUTCForTests,
            now: now.addingTimeInterval(-86_400)
        )

        XCTAssertEqual(
            agentUsageDayIdentifier(for: dates.startDate, calendar: .gregorianUTCForTests),
            19_912
        )
        XCTAssertEqual(
            agentUsageDayIdentifier(for: dates.endDate, calendar: .gregorianUTCForTests),
            19_912
        )
    }

    func testCalendarDatesForExplicitRangeNormalizeReversedEndpoints() {
        let dates = agentDateSelectionCalendarDates(
            for: .dayRange(startDay: 19_911, endDay: 19_909),
            calendar: .gregorianUTCForTests,
            now: Date(timeIntervalSince1970: 1_720_558_400)
        )

        XCTAssertEqual(
            agentUsageDayIdentifier(for: dates.startDate, calendar: .gregorianUTCForTests),
            19_909
        )
        XCTAssertEqual(
            agentUsageDayIdentifier(for: dates.endDate, calendar: .gregorianUTCForTests),
            19_911
        )
    }

    func testAssigningDateToActiveInputOnlyUpdatesThatEndpoint() {
        let start = Date(timeIntervalSince1970: 1_720_224_000)
        let end = Date(timeIntervalSince1970: 1_720_396_800)
        let updated = Date(timeIntervalSince1970: 1_720_483_200)

        let startResult = agentDateSelectionDates(
            byAssigning: updated,
            to: .start,
            startDate: start,
            endDate: end
        )
        XCTAssertEqual(startResult.startDate, updated)
        XCTAssertEqual(startResult.endDate, end)

        let endResult = agentDateSelectionDates(
            byAssigning: updated,
            to: .end,
            startDate: start,
            endDate: end
        )
        XCTAssertEqual(endResult.startDate, start)
        XCTAssertEqual(endResult.endDate, updated)
    }

    func testExplicitDateSelectionUsesCustomDisplayLabel() {
        XCTAssertEqual(AgentDateSelection.singleDay(123).displayLabel, "Custom Range")
        XCTAssertEqual(AgentDateSelection.dayRange(startDay: 100, endDay: 104).displayLabel, "Custom Range")
    }

    func testDateSelectionCustomPillLabelDefaultsWhenPresetIsInlineShortcut() {
        XCTAssertEqual(
            AgentDateSelectionInlineTagLabel.customText(for: .preset(.today), calendar: .gregorianUTCForTests),
            "Custom"
        )
        XCTAssertEqual(
            AgentDateSelectionInlineTagLabel.customText(for: .preset(.allTime), calendar: .gregorianUTCForTests),
            "Custom"
        )
    }

    func testDateSelectionCustomPillLabelReflectsNonInlineSelection() {
        XCTAssertEqual(
            AgentDateSelectionInlineTagLabel.customText(for: .preset(.last7Days), calendar: .gregorianUTCForTests),
            "7 Days"
        )
        XCTAssertEqual(
            AgentDateSelectionInlineTagLabel.customText(for: .singleDay(19_909), calendar: .gregorianUTCForTests),
            "Jul 5, 2024"
        )
    }

    func testDateSelectionCustomPillLabelUsesRememberedDraftForInlineShortcutSelections() {
        XCTAssertEqual(
            agentDateSelectionCustomTagText(
                activeSelection: .preset(.today),
                customDraftSelection: .dayRange(startDay: 19_909, endDay: 19_911),
                calendar: .gregorianUTCForTests
            ),
            "Jul 5 - Jul 7"
        )
        XCTAssertEqual(
            agentDateSelectionCustomTagText(
                activeSelection: .preset(.allTime),
                customDraftSelection: .singleDay(19_909),
                calendar: .gregorianUTCForTests
            ),
            "Jul 5, 2024"
        )
    }

    func testCustomTagPrimaryActionOpensPopoverWithoutRememberedRange() {
        XCTAssertEqual(
            agentDateSelectionCustomTagPrimaryAction(
                activeSelection: .preset(.today),
                customDraftSelection: nil
            ),
            .openPopover
        )
    }

    func testCustomTagPrimaryActionAppliesRememberedRangeForInlineShortcutSelections() {
        XCTAssertEqual(
            agentDateSelectionCustomTagPrimaryAction(
                activeSelection: .preset(.today),
                customDraftSelection: .dayRange(startDay: 19_909, endDay: 19_911)
            ),
            .applySelection(.dayRange(startDay: 19_909, endDay: 19_911))
        )
        XCTAssertEqual(
            agentDateSelectionCustomTagPrimaryAction(
                activeSelection: .preset(.allTime),
                customDraftSelection: .singleDay(19_909)
            ),
            .applySelection(.singleDay(19_909))
        )
    }

    func testDateSelectionDraftStorageRoundTripsCustomRange() {
        let defaults = UserDefaults(suiteName: #function)!
        let selection = AgentDateSelection.dayRange(startDay: 100, endDay: 104)

        AgentDateSelectionDraftStorage.save(selection, userDefaults: defaults)

        XCTAssertEqual(
            AgentDateSelectionDraftStorage.load(userDefaults: defaults),
            selection
        )
    }

    func testLegacyPresetRawValueMigratesToPresetSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.set("last_7_days", forKey: "agentUsageSelectedTimeRange")

        let selection = AgentDateSelectionStorage.load(
            userDefaults: defaults,
            calendar: .gregorianUTCForTests,
            now: Date(timeIntervalSince1970: 1_720_558_400)
        )

        XCTAssertEqual(selection, .preset(.last7Days))
    }

    func testExplicitRangeRoundTripsThroughStorage() {
        let defaults = UserDefaults(suiteName: #function)!
        let selection = AgentDateSelection.dayRange(startDay: 100, endDay: 104)

        AgentDateSelectionStorage.save(selection, userDefaults: defaults)

        XCTAssertEqual(
            AgentDateSelectionStorage.load(
                userDefaults: defaults,
                calendar: .gregorianUTCForTests,
                now: Date()
            ),
            selection
        )
    }

    func testInvalidNewFormatStateFallsBackToLegacyPreset() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.set("last_30_days", forKey: "agentUsageSelectedTimeRange")
        defaults.set("range", forKey: "agentUsageDateSelectionKind")
        defaults.set(12, forKey: "agentUsageDateStartDay")

        let selection = AgentDateSelectionStorage.load(
            userDefaults: defaults,
            calendar: .gregorianUTCForTests,
            now: Date(timeIntervalSince1970: 1_720_558_400)
        )

        XCTAssertEqual(selection, .preset(.last30Days))
    }

    func testSelectionScopeUsesSessionOnlyWhenProjectAndSessionExistAndSourceIsNotAll() {
        let sessionSelection = AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: "/tmp/pulse",
            sessionID: "thread_1",
            modelGroupBy: .model
        )

        XCTAssertEqual(
            sessionSelection.scope,
            .session(projectDirectory: "/tmp/pulse", sessionID: "thread_1")
        )
        XCTAssertTrue(sessionSelection.isSessionScope)

        let missingSessionSelection = AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: "/tmp/pulse",
            sessionID: nil,
            modelGroupBy: .model
        )

        XCTAssertEqual(missingSessionSelection.scope, .project(directory: "/tmp/pulse"))
        XCTAssertFalse(missingSessionSelection.isSessionScope)

        let allSourceSelection = AgentUsageSelection(
            source: .all,
            timeRange: .today,
            projectDirectory: "/tmp/pulse",
            sessionID: "thread_1",
            modelGroupBy: .model
        )

        XCTAssertEqual(allSourceSelection.scope, .project(directory: "/tmp/pulse"))
        XCTAssertFalse(allSourceSelection.isSessionScope)
    }

    func testSelectionScopeUsesAllProjectsWhenProjectIsNil() {
        let selection = AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: "thread_1",
            modelGroupBy: .provider
        )

        XCTAssertEqual(selection.scope, .allProjects)
        XCTAssertFalse(selection.isSessionScope)
    }

    func testLoadedStateEmptyStartsWithEmptyCodexDetailCache() {
        XCTAssertEqual(AgentUsageLoadedState.empty.codexDetailCache, [:])
        XCTAssertEqual(AgentUsageLoadedState.empty.refreshGeneration, 0)
    }

    func testDerivedDataForAllSourceMergesSummariesAndShowsTokenFlow() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [makeOpenCodeSession(id: "oc_1", tokens: 120)]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "cx_1", tokens: 80)]),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 200)
        XCTAssertTrue(data.showsTokenFlow)
        XCTAssertFalse(data.isSessionScope)
        XCTAssertTrue(data.sessionOptions.isEmpty)
    }

    func testDerivedDataForCodexSessionHidesByModelAndCarriesDetailThreadID() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "thread_1", tokens: 80)]),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: "thread_1",
            modelGroupBy: .provider
        ))

        XCTAssertTrue(data.isSessionScope)
        XCTAssertFalse(data.showsByModel)
        XCTAssertEqual(data.codexDetailThreadID, "thread_1")
    }

    func testDerivedDataForCodexPreservesDetailedSummaryFields() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [
                    makeCodexSession(
                        id: "thread_1",
                        tokens: 120,
                        inputTokens: 100,
                        outputTokens: 20,
                        reasoningTokens: 5,
                        cacheReadTokens: 40
                    )
                ]),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 120)
        XCTAssertEqual(data.summary.inputTokens, 100)
        XCTAssertEqual(data.summary.outputTokens, 20)
        XCTAssertEqual(data.summary.reasoningTokens, 5)
        XCTAssertEqual(data.summary.cacheReadTokens, 40)
        XCTAssertNil(data.summary.cacheWriteTokens)
    }

    func testDerivedDataForAllTimeCarriesMultiDayBucketSizeWhenRangeIsCompressed() {
        let now = Date()
        let oldestDate = Calendar.current.date(byAdding: .day, value: -32, to: now) ?? now
        let recentDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    makeOpenCodeSession(id: "oc_old", tokens: 120, updatedAt: oldestDate),
                    makeOpenCodeSession(id: "oc_recent", tokens: 80, updatedAt: recentDate)
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertFalse(data.tokenFlowData.isEmpty)
        XCTAssertEqual(data.tokenFlowData.first?.bucketSizeDays, 2)
    }

    func testDerivedDataForRangedAllSourceHidesTokenActivityWhenOnlyOneSourceHasBuckets() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let todayDay = agentUsageDayIdentifier(for: today)

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    makeOpenCodeSession(id: "oc_1", tokens: 999, updatedAt: now)
                ]),
                openCodeDailyBuckets: [
                    OpenCodeDailyBucket(
                        sessionID: "oc_1",
                        day: todayDay,
                        inputTokens: 10,
                        outputTokens: 5,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 0,
                        cost: 0
                    )
                ],
                codexSnapshot: CodexUsageSnapshot(sessions: [
                    makeCodexSession(
                        id: "cx_1",
                        tokens: 80,
                        updatedAt: now
                    )
                ]),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .all,
            timeRange: .last7Days,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.summary.totalTokens, 95)
        XCTAssertFalse(data.showsTokenFlow)
        XCTAssertTrue(data.tokenFlowData.isEmpty)
        XCTAssertTrue(data.activityCalendarData.isEmpty)
    }

    func testDataSourceDescriptionForCodexMentionsDatabaseAndTranscripts() {
        let description = AgentUsageDataSourceDescription.message(
            for: .codex,
            openCodeDatabaseURL: URL(fileURLWithPath: "/Users/zyao/.local/share/opencode/opencode.db"),
            codexDatabaseURL: URL(fileURLWithPath: "/Users/zyao/.codex/sqlite/state_5.sqlite")
        )

        XCTAssertEqual(
            description,
            "Pulse reads Codex session metadata from /Users/zyao/.codex/sqlite/state_5.sqlite and derives token usage from local transcripts under ~/.codex when you refresh the panel."
        )
    }

    func testDerivedDataForCodexEnrichesRequestCountFromDailyBuckets() {
        let store = AgentUsageStore(repository: StubRepository())
        let now = Date()
        let todayDay = agentUsageDayIdentifier(for: now)
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [makeCodexSession(id: "t1", tokens: 100)]),
                codexDailyBuckets: [
                    CodexDailyBucket(
                        sessionID: "t1",
                        day: todayDay,
                        inputTokens: 80,
                        outputTokens: 20,
                        reasoningTokens: 0,
                        cacheReadTokens: 40,
                        totalTokens: 100,
                        requestCount: 5,
                        latestActivityAt: now
                    )
                ],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )
        let data = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        XCTAssertEqual(data.summary.requestCount, 5)
    }

    func testDerivedDataForCodexProjectRequestCountExcludesSubagentBuckets() {
        let store = AgentUsageStore(repository: StubRepository())
        let now = Date()
        let todayDay = agentUsageDayIdentifier(for: now)
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: []),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: [
                    makeCodexSession(id: "primary", tokens: 100),
                    CodexSessionRecord(
                        id: "subagent",
                        title: "Subagent",
                        cwd: "/Users/zyao/Desktop/pulse",
                        model: "gpt-5",
                        modelProvider: "openai",
                        tokensUsed: 50,
                        inputTokens: 40,
                        outputTokens: 10,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        reasoningEffort: "",
                        threadSource: "subagent",
                        agentNickname: nil,
                        agentRole: nil,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    )
                ]),
                codexDailyBuckets: [
                    CodexDailyBucket(
                        sessionID: "primary",
                        day: todayDay,
                        inputTokens: 80,
                        outputTokens: 20,
                        reasoningTokens: 0,
                        cacheReadTokens: 40,
                        totalTokens: 100,
                        requestCount: 5,
                        latestActivityAt: now
                    ),
                    CodexDailyBucket(
                        sessionID: "subagent",
                        day: todayDay,
                        inputTokens: 40,
                        outputTokens: 10,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        totalTokens: 50,
                        requestCount: 7,
                        latestActivityAt: now
                    )
                ],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )
        let data = store.derivedData(for: AgentUsageSelection(
            source: .codex,
            timeRange: .today,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: nil,
            modelGroupBy: .model
        ))
        XCTAssertEqual(data.summary.requestCount, 5)
    }

    func testDerivedDataForOpenCodeRangedSessionUsesBucketActivityForSelectedCompoundSession() {
        let now = Date()
        let activityAt = now.addingTimeInterval(-60)
        let day = agentUsageDayIdentifier(for: now)
        let compoundID = "oc_1::opencode::model-a::"

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    makeOpenCodeSession(id: "oc_1", tokens: 999, updatedAt: now.addingTimeInterval(-3600))
                ]),
                openCodeDailyBuckets: [
                    OpenCodeDailyBucket(
                        sessionID: "oc_1",
                        day: day,
                        modelProviderID: "opencode",
                        modelID: "model-a",
                        modelVariant: nil,
                        inputTokens: 80,
                        outputTokens: 20,
                        reasoningTokens: 5,
                        cacheReadTokens: 40,
                        cacheWriteTokens: 3,
                        requestCount: 2,
                        cost: 0.01,
                        latestActivityAt: activityAt
                    )
                ],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .today,
            projectDirectory: "/Users/zyao/Desktop/pulse",
            sessionID: compoundID,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.selectedOpenCodeSession?.id, compoundID)
        XCTAssertEqual(data.selectedOpenCodeSession?.updatedAt, activityAt)
    }

    func testDerivedDataForOpenCodeExplicitDateWithoutBucketsUsesSnapshotBreakdowns() {
        let selectedDate = Date(timeIntervalSince1970: 1_737_201_600)
        let selectedDay = agentUsageDayIdentifier(for: selectedDate)
        let outsideDate = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate.addingTimeInterval(-86_400)

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "oc_1",
                        title: "OpenCode Selected",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet",
                        modelVariant: nil,
                        inputTokens: 70,
                        outputTokens: 10,
                        reasoningTokens: 0,
                        cacheReadTokens: 5,
                        cacheWriteTokens: 0,
                        requestCount: 1,
                        cost: 0,
                        createdAt: selectedDate,
                        updatedAt: selectedDate
                    ),
                    OpenCodeSessionRecord(
                        id: "oc_2",
                        title: "OpenCode Outside",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "openai",
                        modelID: "gpt-5",
                        modelVariant: nil,
                        inputTokens: 30,
                        outputTokens: 10,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 1,
                        cost: 0,
                        createdAt: outsideDate,
                        updatedAt: outsideDate
                    )
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            dateSelection: .singleDay(selectedDay),
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        XCTAssertEqual(data.providerBreakdown.map(\.provider), ["anthropic"])
        XCTAssertEqual(data.providerBreakdown.first?.summary.totalTokens, 85)
        XCTAssertEqual(data.modelBreakdownRows.count, 1)
        XCTAssertEqual(data.modelBreakdownRows.first?.id, "anthropic::claude-sonnet::")
        XCTAssertEqual(data.modelBreakdownRows.first?.title, OpenCodeUsageSnapshot.modelDisplayName(providerID: "anthropic", modelID: "claude-sonnet", variant: nil))
        XCTAssertEqual(data.modelBreakdownRows.first?.valueText, "85")
    }

    func testBuildSummaryPillsIncludesHitRateWhenCacheReadAndInputAvailable() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "s1",
                        title: "Test",
                        directory: "/tmp",
                        agent: "build",
                        modelProviderID: "opencode",
                        modelID: "model-a",
                        modelVariant: nil,
                        inputTokens: 100,
                        outputTokens: 20,
                        reasoningTokens: 0,
                        cacheReadTokens: 60,
                        cacheWriteTokens: 0,
                        requestCount: 3,
                        cost: 0,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    )
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )
        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let hitRatePill = data.summaryPills.first { $0.id == "hitRate" }
        XCTAssertNotNil(hitRatePill)
        XCTAssertEqual(hitRatePill?.valueText, "38%")
    }

    func testBuildSummaryPillsOmitsHitRateWhenNoCacheReadTokens() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "s1",
                        title: "Test",
                        directory: "/tmp",
                        agent: "build",
                        modelProviderID: "opencode",
                        modelID: "model-a",
                        modelVariant: nil,
                        inputTokens: 0,
                        outputTokens: 20,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 2,
                        cost: 0,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    )
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )
        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let hitRatePill = data.summaryPills.first { $0.id == "hitRate" }
        XCTAssertNil(hitRatePill)
    }

    func testModelBreakdownRowsDeduplicatesCompoundSessionIDsForAllTime() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "ses_1::anthropic::claude-sonnet-4-20250514::",
                        title: "Multi-model session",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: nil,
                        inputTokens: 100,
                        outputTokens: 50,
                        reasoningTokens: 10,
                        cacheReadTokens: 20,
                        cacheWriteTokens: 5,
                        requestCount: 3,
                        cost: 0.01,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    ),
                    OpenCodeSessionRecord(
                        id: "ses_1::anthropic::claude-sonnet-4-20250514::thinking",
                        title: "Multi-model session",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: "thinking",
                        inputTokens: 200,
                        outputTokens: 80,
                        reasoningTokens: 50,
                        cacheReadTokens: 30,
                        cacheWriteTokens: 8,
                        requestCount: 5,
                        cost: 0.03,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 3000)
                    )
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        let uniqueIDs = Set(data.modelBreakdownRows.map(\.id))
        XCTAssertEqual(data.modelBreakdownRows.count, uniqueIDs.count, "modelBreakdownRows contains duplicate ids")
        XCTAssertEqual(data.modelBreakdownRows.count, 2, "Should have two distinct model entries (default + thinking)")
        let defaultRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514" }
        let thinkingRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514 (thinking)" }
        XCTAssertNotNil(defaultRow)
        XCTAssertNotNil(thinkingRow)
        XCTAssertEqual(defaultRow?.id, "anthropic::claude-sonnet-4-20250514::")
        XCTAssertEqual(thinkingRow?.id, "anthropic::claude-sonnet-4-20250514::thinking")
    }

    func testModelBreakdownRowsDeduplicatesVariantBucketsForRangedTime() {
        let todayDay = agentUsageDayIdentifier(for: Date())

        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "ses_1",
                        title: "Session ses_1",
                        directory: "/Users/zyao/Desktop/pulse",
                        agent: "build",
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: nil,
                        inputTokens: 500,
                        outputTokens: 0,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 0,
                        cost: 0,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ]),
                openCodeDailyBuckets: [
                    OpenCodeDailyBucket(
                        sessionID: "ses_1",
                        day: todayDay,
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: nil,
                        inputTokens: 100,
                        outputTokens: 50,
                        reasoningTokens: 10,
                        cacheReadTokens: 20,
                        cacheWriteTokens: 5,
                        requestCount: 3,
                        cost: 0.01
                    ),
                    OpenCodeDailyBucket(
                        sessionID: "ses_1",
                        day: todayDay,
                        modelProviderID: "anthropic",
                        modelID: "claude-sonnet-4-20250514",
                        modelVariant: "thinking",
                        inputTokens: 200,
                        outputTokens: 80,
                        reasoningTokens: 50,
                        cacheReadTokens: 30,
                        cacheWriteTokens: 8,
                        requestCount: 5,
                        cost: 0.03
                    )
                ],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )

        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .today,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))

        let uniqueIDs = Set(data.modelBreakdownRows.map(\.id))
        XCTAssertEqual(data.modelBreakdownRows.count, uniqueIDs.count, "modelBreakdownRows contains duplicate ids for ranged time")
        XCTAssertEqual(data.modelBreakdownRows.count, 2, "Should have two distinct model entries for ranged time (default + thinking)")
        let defaultRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514" }
        let thinkingRow = data.modelBreakdownRows.first { $0.title == "anthropic / claude-sonnet-4-20250514 (thinking)" }
        XCTAssertNotNil(defaultRow)
        XCTAssertNotNil(thinkingRow)
        XCTAssertEqual(defaultRow?.id, "anthropic::claude-sonnet-4-20250514::")
        XCTAssertEqual(thinkingRow?.id, "anthropic::claude-sonnet-4-20250514::thinking")
    }

    func testBuildUsageMetricsIncludesRequestsCard() {
        let store = AgentUsageStore(repository: StubRepository())
        store.replaceStateForTesting(
            AgentUsageLoadedState(
                openCodeCumulativeSnapshot: OpenCodeUsageSnapshot(sessions: [
                    OpenCodeSessionRecord(
                        id: "s1",
                        title: "Test",
                        directory: "/tmp",
                        agent: "build",
                        modelProviderID: "opencode",
                        modelID: "model-a",
                        modelVariant: nil,
                        inputTokens: 100,
                        outputTokens: 0,
                        reasoningTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        requestCount: 15,
                        cost: 0,
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 2000)
                    )
                ]),
                openCodeDailyBuckets: [],
                codexSnapshot: CodexUsageSnapshot(sessions: []),
                codexDailyBuckets: [],
                refreshGeneration: 1,
                codexDetailCache: [:]
            )
        )
        let data = store.derivedData(for: AgentUsageSelection(
            source: .openCode,
            timeRange: .allTime,
            projectDirectory: nil,
            sessionID: nil,
            modelGroupBy: .model
        ))
        let requestsCard = data.usageMetrics.first { $0.id == "requests" }
        XCTAssertNotNil(requestsCard)
        XCTAssertEqual(requestsCard?.title, "Requests")
    }

    func testCodexSessionDetailIsEmptyWhenNoEdgesOrGoalsExist() {
        let detail = CodexSessionDetail(
            threadID: "thread_1",
            edges: [],
            goals: []
        )

        XCTAssertTrue(detail.isEmpty)
    }

    func testCodexSessionDetailIsNotEmptyWhenEdgesExist() {
        let detail = CodexSessionDetail(
            threadID: "thread_1",
            edges: [
                CodexSubagentEdge(
                    parentThreadID: "thread_1",
                    childThreadID: "thread_2",
                    status: "complete"
                )
            ],
            goals: []
        )

        XCTAssertFalse(detail.isEmpty)
    }

    func testCodexSessionDetailIsNotEmptyWhenGoalsExist() {
        let detail = CodexSessionDetail(
            threadID: "thread_1",
            edges: [],
            goals: [
                CodexGoal(
                    id: "goal_1",
                    threadID: "thread_1",
                    objective: "Ship the fix",
                    status: "active",
                    tokenBudget: 1_000,
                    tokensUsed: 120
                )
            ]
        )

        XCTAssertFalse(detail.isEmpty)
    }
}

private extension Calendar {
    static var gregorianUTCForTests: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static var gregorianPacificForTests: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
}

private func makeOpenCodeSession(id: String, tokens: Int = 100, updatedAt: Date = Date(timeIntervalSince1970: 2000)) -> OpenCodeSessionRecord {
    OpenCodeSessionRecord(
        id: id,
        title: "Session \(id)",
        directory: "/Users/zyao/Desktop/pulse",
        agent: "build",
        modelProviderID: "opencode",
        modelID: "model-a",
        modelVariant: nil,
        inputTokens: tokens,
        outputTokens: 0,
        reasoningTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        requestCount: 0,
        cost: 0,
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: updatedAt
    )
}

private func makeCodexSession(
    id: String,
    tokens: Int = 100,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    cacheReadTokens: Int? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 2000)
) -> CodexSessionRecord {
    CodexSessionRecord(
        id: id,
        title: "Session \(id)",
        cwd: "/Users/zyao/Desktop/pulse",
        model: "gpt-5",
        modelProvider: "openai",
        tokensUsed: tokens,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        cacheReadTokens: cacheReadTokens,
        reasoningEffort: "",
        threadSource: "primary",
        agentNickname: nil,
        agentRole: nil,
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: updatedAt
    )
}

private final class StubRepository: AgentUsageRepositorying {
    var openCodeDatabaseURL = URL(fileURLWithPath: "/tmp/opencode.db")
    var codexDatabaseURL: URL? = URL(fileURLWithPath: "/tmp/codex.db")
    func loadOpenCodeCumulativeSnapshot() throws -> OpenCodeUsageSnapshot { OpenCodeUsageSnapshot(sessions: []) }
    func loadOpenCodeDailyBuckets() throws -> [OpenCodeDailyBucket] { [] }
    func loadCodexSnapshot() throws -> CodexUsageSnapshot { CodexUsageSnapshot(sessions: []) }
    func loadCodexDailyBuckets() throws -> [CodexDailyBucket] { [] }
    func loadCodexDetail(
        threadID: String,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> CodexSessionDetail {
        CodexSessionDetail(threadID: threadID, edges: [], goals: [])
    }
}
