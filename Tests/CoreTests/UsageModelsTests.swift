import Foundation
import XCTest

final class UsageModelsTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testBuildsRemainingPercentageFromPrimaryCodexBucket() throws {
        let data = Data(
            #"{"rateLimits":{"primary":{"usedPercent":70,"windowDurationMins":300,"resetsAt":1000},"credits":{"unlimited":false},"rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":2000},"credits":{"unlimited":false},"rateLimitReachedType":null}}}"#.utf8
        )
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
        let fetchedAt = Date(timeIntervalSince1970: 500)

        let snapshot = try UsageSnapshotBuilder.build(from: result, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.kind, .percentage)
        XCTAssertEqual(snapshot.remainingPercent, 75)
        XCTAssertEqual(snapshot.windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testClampsOutOfRangeUsage() throws {
        let data = Data(
            #"{"rateLimits":{"primary":{"usedPercent":140,"windowDurationMins":300,"resetsAt":1000},"credits":null,"rateLimitReachedType":null}}"#.utf8
        )
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)

        let snapshot = try UsageSnapshotBuilder.build(from: result)

        XCTAssertEqual(snapshot.usedPercent, 100)
        XCTAssertEqual(snapshot.remainingPercent, 0)
    }

    func testUnlimitedCreditsUseUnlimitedState() throws {
        let data = Data(
            #"{"rateLimits":{"primary":null,"credits":{"unlimited":true},"rateLimitReachedType":null}}"#.utf8
        )
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)

        let snapshot = try UsageSnapshotBuilder.build(from: result)

        XCTAssertEqual(snapshot.kind, .unlimited)
        XCTAssertNil(snapshot.remainingPercent)
    }

    func testSnapshotStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageSnapshotStore(directory: directory)
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            kind: .percentage,
            remainingPercent: 88,
            usedPercent: 12,
            windowDurationMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_000),
            fetchedAt: Date(timeIntervalSince1970: 500),
            dailyUsage: DailyUsageState(
                dayStartedAt: Date(timeIntervalSince1970: 0),
                segmentInitialRemainingPercent: 94,
                accumulatedBeforeSegmentPercent: 0,
                usedPercent: 6,
                lastRemainingPercent: 88,
                lastResetsAt: Date(timeIntervalSince1970: 1_000)
            ),
            dailyUsageHistory: (0..<DailyUsageHistoryTracker.capacity).map { index in
                DailyUsageDay(
                    dayStartedAt: Date(timeIntervalSince1970: Double(index * 86_400)),
                    usedPercent: Double(index * 10)
                )
            }
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
    }

    func testDailyUsageStartsAtZeroAndTracksSameDayConsumption() {
        let first = percentageSnapshot(remaining: 94, fetchedAt: 1_000, resetsAt: 20_000)
        let initial = DailyUsageTracker.update(
            previous: nil,
            with: first,
            calendar: utcCalendar
        )

        XCTAssertEqual(initial?.usedPercent, 0)

        let later = percentageSnapshot(remaining: 80, fetchedAt: 2_000, resetsAt: 20_000)
        let updated = DailyUsageTracker.update(
            previous: initial,
            with: later,
            calendar: utcCalendar
        )

        XCTAssertEqual(updated?.usedPercent, 14)
    }

    func testDailyUsageCountsConsumptionAlreadySeenAfterLimitReset() {
        let initial = DailyUsageTracker.update(
            previous: nil,
            with: percentageSnapshot(remaining: 94, fetchedAt: 1_000, resetsAt: 5_000),
            calendar: utcCalendar
        )
        let beforeReset = DailyUsageTracker.update(
            previous: initial,
            with: percentageSnapshot(remaining: 80, fetchedAt: 4_000, resetsAt: 5_000),
            calendar: utcCalendar
        )
        let afterReset = DailyUsageTracker.update(
            previous: beforeReset,
            with: percentageSnapshot(remaining: 99, fetchedAt: 6_000, resetsAt: 10_000),
            calendar: utcCalendar
        )
        let afterMoreUsage = DailyUsageTracker.update(
            previous: afterReset,
            with: percentageSnapshot(remaining: 93, fetchedAt: 7_000, resetsAt: 10_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(beforeReset?.usedPercent, 14)
        XCTAssertEqual(afterReset?.segmentInitialRemainingPercent, 100)
        XCTAssertEqual(afterReset?.usedPercent, 15)
        XCTAssertEqual(afterMoreUsage?.usedPercent, 21)
    }

    func testDailyUsageIgnoresResetTimeJitter() {
        let today = date(year: 2026, month: 9, day: 4)
        let resetsAt = date(year: 2026, month: 9, day: 7)
        let previous = DailyUsageState(
            dayStartedAt: today,
            segmentInitialRemainingPercent: 31,
            accumulatedBeforeSegmentPercent: 0,
            usedPercent: 3,
            lastRemainingPercent: 28,
            lastResetsAt: resetsAt
        )
        let earlierJitter = DailyUsageTracker.update(
            previous: previous,
            with: percentageSnapshot(
                remaining: 28,
                fetchedAt: today.addingTimeInterval(10 * 60 * 60).timeIntervalSince1970,
                resetsAt: resetsAt.addingTimeInterval(-1).timeIntervalSince1970
            ),
            calendar: utcCalendar
        )
        let laterJitter = DailyUsageTracker.update(
            previous: earlierJitter,
            with: percentageSnapshot(
                remaining: 27,
                fetchedAt: today.addingTimeInterval(10 * 60 * 60 + 15 * 60).timeIntervalSince1970,
                resetsAt: resetsAt.addingTimeInterval(1).timeIntervalSince1970
            ),
            calendar: utcCalendar
        )

        XCTAssertEqual(laterJitter?.segmentInitialRemainingPercent, 31)
        XCTAssertEqual(laterJitter?.accumulatedBeforeSegmentPercent, 0)
        XCTAssertEqual(laterJitter?.usedPercent, 4)
    }

    func testDailyUsageRepairsMissedConsumptionWhenWindowResetEarlierToday() {
        let dayStartedAt = date(year: 2026, month: 8, day: 26)
        let windowStartedAt = dayStartedAt.addingTimeInterval(2 * 60 * 60)
        let resetsAt = windowStartedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = DailyUsageState(
            dayStartedAt: dayStartedAt,
            segmentInitialRemainingPercent: 99,
            accumulatedBeforeSegmentPercent: 0,
            usedPercent: 0,
            lastRemainingPercent: 99,
            lastResetsAt: resetsAt
        )
        let snapshot = percentageSnapshot(
            remaining: 99,
            fetchedAt: dayStartedAt.addingTimeInterval(3 * 60 * 60).timeIntervalSince1970,
            resetsAt: resetsAt.timeIntervalSince1970
        )

        let repaired = DailyUsageTracker.update(
            previous: previous,
            with: snapshot,
            calendar: utcCalendar
        )

        XCTAssertEqual(repaired?.segmentInitialRemainingPercent, 100)
        XCTAssertEqual(repaired?.usedPercent, 1)
    }

    func testDailyUsageInfersConsumptionOnFirstFetchWhenWindowResetEarlierToday() {
        let dayStartedAt = date(year: 2026, month: 8, day: 26)
        let windowStartedAt = dayStartedAt.addingTimeInterval(2 * 60 * 60)
        let resetsAt = windowStartedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let snapshot = percentageSnapshot(
            remaining: 99,
            fetchedAt: dayStartedAt.addingTimeInterval(3 * 60 * 60).timeIntervalSince1970,
            resetsAt: resetsAt.timeIntervalSince1970
        )

        let initial = DailyUsageTracker.update(
            previous: nil,
            with: snapshot,
            calendar: utcCalendar
        )

        XCTAssertEqual(initial?.segmentInitialRemainingPercent, 100)
        XCTAssertEqual(initial?.usedPercent, 1)
    }

    func testDailyUsageAttributesObservedCrossMidnightDecreaseToNewDay() {
        let initial = DailyUsageTracker.update(
            previous: nil,
            with: percentageSnapshot(remaining: 90, fetchedAt: 1_000, resetsAt: 100_000),
            calendar: utcCalendar
        )
        let sameDay = DailyUsageTracker.update(
            previous: initial,
            with: percentageSnapshot(remaining: 75, fetchedAt: 2_000, resetsAt: 100_000),
            calendar: utcCalendar
        )
        let nextDay = DailyUsageTracker.update(
            previous: sameDay,
            with: percentageSnapshot(remaining: 70, fetchedAt: 90_000, resetsAt: 100_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(sameDay?.usedPercent, 15)
        XCTAssertEqual(nextDay?.usedPercent, 5)
        XCTAssertEqual(nextDay?.segmentInitialRemainingPercent, 75)
    }

    func testDailyUsageDoesNotCreateUsageForCrossMidnightIncreaseWithoutReset() {
        let initial = DailyUsageTracker.update(
            previous: nil,
            with: percentageSnapshot(remaining: 70, fetchedAt: 1_000, resetsAt: 100_000),
            calendar: utcCalendar
        )
        let correctedNextDay = DailyUsageTracker.update(
            previous: initial,
            with: percentageSnapshot(remaining: 72, fetchedAt: 90_000, resetsAt: 100_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(correctedNextDay?.usedPercent, 0)
        XCTAssertEqual(correctedNextDay?.segmentInitialRemainingPercent, 72)
    }

    func testDailyUsageStartsAtFirstObservationWhenLimitResetOnPreviousDay() {
        let yesterday = date(year: 2026, month: 8, day: 26)
        let today = date(year: 2026, month: 8, day: 27)
        let resetOnYesterday = yesterday.addingTimeInterval(10 * 60 * 60)
        let nextReset = resetOnYesterday.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = DailyUsageState(
            dayStartedAt: yesterday,
            segmentInitialRemainingPercent: 58,
            accumulatedBeforeSegmentPercent: 0,
            usedPercent: 18,
            lastRemainingPercent: 40,
            lastResetsAt: resetOnYesterday
        )
        let firstObservationToday = percentageSnapshot(
            remaining: 82,
            fetchedAt: today.addingTimeInterval(18 * 60 * 60).timeIntervalSince1970,
            resetsAt: nextReset.timeIntervalSince1970
        )

        let updated = DailyUsageTracker.update(
            previous: previous,
            with: firstObservationToday,
            calendar: utcCalendar
        )

        XCTAssertEqual(updated?.dayStartedAt, today)
        XCTAssertEqual(updated?.segmentInitialRemainingPercent, 82)
        XCTAssertEqual(updated?.usedPercent, 0)
    }

    func testDailyUsageRepairClearsDuplicatedTodayAndPreservesYesterday() {
        let yesterday = date(year: 2026, month: 8, day: 26)
        let today = date(year: 2026, month: 8, day: 27)
        let legacySnapshot = UsageSnapshot(
            schemaVersion: 2,
            kind: .percentage,
            remainingPercent: 82,
            usedPercent: 18,
            windowDurationMinutes: 10_080,
            resetsAt: date(year: 2026, month: 9, day: 2),
            fetchedAt: today.addingTimeInterval(18 * 60 * 60),
            dailyUsage: dailyUsageState(dayStartedAt: today, usedPercent: 18),
            dailyUsageHistory: [
                DailyUsageDay(dayStartedAt: yesterday, usedPercent: 18),
                DailyUsageDay(dayStartedAt: today, usedPercent: 18)
            ]
        )

        let seed = DailyUsageTrackingRepair.prepare(
            previous: legacySnapshot,
            at: legacySnapshot.fetchedAt,
            calendar: utcCalendar
        )
        let current = DailyUsageTracker.update(
            previous: seed.dailyUsage,
            with: legacySnapshot,
            calendar: utcCalendar
        )
        let history = DailyUsageHistoryTracker.update(
            previous: seed.dailyUsageHistory,
            previousDailyUsage: seed.dailyUsage,
            currentDailyUsage: current,
            at: legacySnapshot.fetchedAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(seed.dailyUsage?.usedPercent, 0)
        XCTAssertEqual(current?.usedPercent, 0)
        XCTAssertEqual(history[5].dayStartedAt, yesterday)
        XCTAssertEqual(history[5].usedPercent, 18)
        XCTAssertEqual(history[6].dayStartedAt, today)
        XCTAssertEqual(history[6].usedPercent, 0)
    }

    func testDailyUsageRepairSubtractsDuplicatedYesterdayFromCurrentTotal() {
        let yesterday = date(year: 2026, month: 8, day: 26)
        let today = date(year: 2026, month: 8, day: 27)
        let resetsAt = date(year: 2026, month: 9, day: 2)
        let duplicatedSnapshot = UsageSnapshot(
            schemaVersion: 2,
            kind: .percentage,
            remainingPercent: 80,
            usedPercent: 20,
            windowDurationMinutes: 10_080,
            resetsAt: resetsAt,
            fetchedAt: today.addingTimeInterval(18 * 60 * 60),
            dailyUsage: DailyUsageState(
                dayStartedAt: today,
                segmentInitialRemainingPercent: 100,
                accumulatedBeforeSegmentPercent: 0,
                usedPercent: 20,
                lastRemainingPercent: 80,
                lastResetsAt: resetsAt
            ),
            dailyUsageHistory: [
                DailyUsageDay(dayStartedAt: yesterday, usedPercent: 18),
                DailyUsageDay(dayStartedAt: today, usedPercent: 20)
            ]
        )

        let seed = DailyUsageTrackingRepair.prepare(
            previous: duplicatedSnapshot,
            at: duplicatedSnapshot.fetchedAt,
            calendar: utcCalendar
        )
        let current = DailyUsageTracker.update(
            previous: seed.dailyUsage,
            with: duplicatedSnapshot,
            calendar: utcCalendar
        )
        let history = DailyUsageHistoryTracker.update(
            previous: seed.dailyUsageHistory,
            previousDailyUsage: seed.dailyUsage,
            currentDailyUsage: current,
            at: duplicatedSnapshot.fetchedAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(seed.dailyUsage?.segmentInitialRemainingPercent, 82)
        XCTAssertEqual(seed.dailyUsage?.usedPercent, 2)
        XCTAssertEqual(current?.usedPercent, 2)
        XCTAssertEqual(history[5].usedPercent, 18)
        XCTAssertEqual(history[6].usedPercent, 2)
    }

    func testDailyUsageRepairPreservesAlreadyCorrectedToday() {
        let yesterday = date(year: 2026, month: 8, day: 26)
        let today = date(year: 2026, month: 8, day: 27)
        let correctedToday = DailyUsageState(
            dayStartedAt: today,
            segmentInitialRemainingPercent: 82,
            accumulatedBeforeSegmentPercent: 0,
            usedPercent: 2,
            lastRemainingPercent: 80,
            lastResetsAt: date(year: 2026, month: 9, day: 2)
        )
        let snapshot = UsageSnapshot(
            schemaVersion: 2,
            kind: .percentage,
            remainingPercent: 80,
            usedPercent: 20,
            windowDurationMinutes: 10_080,
            resetsAt: date(year: 2026, month: 9, day: 2),
            fetchedAt: today.addingTimeInterval(18 * 60 * 60),
            dailyUsage: correctedToday,
            dailyUsageHistory: [
                DailyUsageDay(dayStartedAt: yesterday, usedPercent: 18),
                DailyUsageDay(dayStartedAt: today, usedPercent: 2)
            ]
        )

        let seed = DailyUsageTrackingRepair.prepare(
            previous: snapshot,
            at: snapshot.fetchedAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(seed.dailyUsage, correctedToday)
        XCTAssertEqual(seed.dailyUsageHistory, snapshot.dailyUsageHistory)
    }

    func testDailyUsageRepairRemovesJitterResetSegmentAndContinuesTracking() {
        let yesterday = date(year: 2026, month: 9, day: 3)
        let today = date(year: 2026, month: 9, day: 4)
        let resetsAt = date(year: 2026, month: 9, day: 7)
        let corruptedSnapshot = UsageSnapshot(
            schemaVersion: 2,
            kind: .percentage,
            remainingPercent: 28,
            usedPercent: 72,
            windowDurationMinutes: 10_080,
            resetsAt: resetsAt,
            fetchedAt: today.addingTimeInterval(10 * 60 * 60),
            dailyUsage: DailyUsageState(
                dayStartedAt: today,
                segmentInitialRemainingPercent: 100,
                accumulatedBeforeSegmentPercent: 3,
                usedPercent: 75,
                lastRemainingPercent: 28,
                lastResetsAt: resetsAt
            ),
            dailyUsageHistory: [
                DailyUsageDay(dayStartedAt: yesterday, usedPercent: 11),
                DailyUsageDay(dayStartedAt: today, usedPercent: 75)
            ]
        )

        let seed = DailyUsageTrackingRepair.prepare(
            previous: corruptedSnapshot,
            at: corruptedSnapshot.fetchedAt,
            calendar: utcCalendar
        )
        let current = DailyUsageTracker.update(
            previous: seed.dailyUsage,
            with: percentageSnapshot(
                remaining: 27,
                fetchedAt: today.addingTimeInterval(10 * 60 * 60 + 15 * 60).timeIntervalSince1970,
                resetsAt: resetsAt.addingTimeInterval(2).timeIntervalSince1970
            ),
            calendar: utcCalendar
        )
        let history = DailyUsageHistoryTracker.update(
            previous: seed.dailyUsageHistory,
            previousDailyUsage: seed.dailyUsage,
            currentDailyUsage: current,
            at: today.addingTimeInterval(10 * 60 * 60 + 15 * 60),
            calendar: utcCalendar
        )

        XCTAssertEqual(seed.dailyUsage?.segmentInitialRemainingPercent, 28)
        XCTAssertEqual(seed.dailyUsage?.accumulatedBeforeSegmentPercent, 3)
        XCTAssertEqual(seed.dailyUsage?.usedPercent, 3)
        XCTAssertEqual(current?.usedPercent, 4)
        XCTAssertEqual(history[5].usedPercent, 11)
        XCTAssertEqual(history[6].usedPercent, 4)
    }

    func testDailyUsageRepairPreservesSameDayResetState() {
        let today = date(year: 2026, month: 9, day: 4)
        let resetsAt = today.addingTimeInterval(7 * 24 * 60 * 60 + 2 * 60 * 60)
        let resetState = DailyUsageState(
            dayStartedAt: today,
            segmentInitialRemainingPercent: 100,
            accumulatedBeforeSegmentPercent: 3,
            usedPercent: 75,
            lastRemainingPercent: 28,
            lastResetsAt: resetsAt
        )
        let snapshot = UsageSnapshot(
            schemaVersion: 2,
            kind: .percentage,
            remainingPercent: 28,
            usedPercent: 72,
            windowDurationMinutes: 10_080,
            resetsAt: resetsAt,
            fetchedAt: today.addingTimeInterval(3 * 60 * 60),
            dailyUsage: resetState,
            dailyUsageHistory: [
                DailyUsageDay(dayStartedAt: today, usedPercent: 75)
            ]
        )

        let seed = DailyUsageTrackingRepair.prepare(
            previous: snapshot,
            at: snapshot.fetchedAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(seed.dailyUsage, resetState)
        XCTAssertEqual(seed.dailyUsageHistory, snapshot.dailyUsageHistory)
    }

    func testDailyUsageNeverMovesBackwardWhenRemainingIncreases() {
        let initial = DailyUsageTracker.update(
            previous: nil,
            with: percentageSnapshot(remaining: 94, fetchedAt: 1_000, resetsAt: 20_000),
            calendar: utcCalendar
        )
        let consumed = DailyUsageTracker.update(
            previous: initial,
            with: percentageSnapshot(remaining: 80, fetchedAt: 2_000, resetsAt: 20_000),
            calendar: utcCalendar
        )
        let corrected = DailyUsageTracker.update(
            previous: consumed,
            with: percentageSnapshot(remaining: 82, fetchedAt: 3_000, resetsAt: 20_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(consumed?.usedPercent, 14)
        XCTAssertEqual(corrected?.usedPercent, 14)
    }

    func testDailyUsageCanExceedOneHundredAcrossReset() {
        let initial = DailyUsageTracker.update(
            previous: nil,
            with: percentageSnapshot(remaining: 100, fetchedAt: 1_000, resetsAt: 5_000),
            calendar: utcCalendar
        )
        let firstWindow = DailyUsageTracker.update(
            previous: initial,
            with: percentageSnapshot(remaining: 0, fetchedAt: 4_000, resetsAt: 5_000),
            calendar: utcCalendar
        )
        let reset = DailyUsageTracker.update(
            previous: firstWindow,
            with: percentageSnapshot(remaining: 100, fetchedAt: 6_000, resetsAt: 10_000),
            calendar: utcCalendar
        )
        let secondWindow = DailyUsageTracker.update(
            previous: reset,
            with: percentageSnapshot(remaining: 80, fetchedAt: 7_000, resetsAt: 10_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(secondWindow?.usedPercent, 120)
    }

    func testDailyUsageHistoryAlwaysContainsSevenDaysEndingToday() {
        let today = date(year: 2026, month: 8, day: 21)
        let history = DailyUsageHistoryTracker.update(
            previous: nil,
            previousDailyUsage: nil,
            currentDailyUsage: dailyUsageState(dayStartedAt: today, usedPercent: 18),
            at: today,
            calendar: utcCalendar
        )

        XCTAssertEqual(history.count, 7)
        XCTAssertEqual(history.first?.dayStartedAt, date(year: 2026, month: 8, day: 15))
        XCTAssertEqual(history.last?.dayStartedAt, today)
        XCTAssertTrue(history.dropLast().allSatisfy { $0.usedPercent == nil })
        XCTAssertEqual(history.last?.usedPercent, 18)
    }

    func testDailyUsageHistoryArchivesYesterdayAfterMidnight() {
        let yesterday = date(year: 2026, month: 8, day: 20)
        let today = date(year: 2026, month: 8, day: 21)
        let yesterdayUsage = dailyUsageState(dayStartedAt: yesterday, usedPercent: 27)
        let previousHistory = DailyUsageHistoryTracker.update(
            previous: nil,
            previousDailyUsage: nil,
            currentDailyUsage: yesterdayUsage,
            at: yesterday,
            calendar: utcCalendar
        )

        let history = DailyUsageHistoryTracker.update(
            previous: previousHistory,
            previousDailyUsage: yesterdayUsage,
            currentDailyUsage: dailyUsageState(dayStartedAt: today, usedPercent: 0),
            at: today,
            calendar: utcCalendar
        )

        XCTAssertEqual(history[5].dayStartedAt, yesterday)
        XCTAssertEqual(history[5].usedPercent, 27)
        XCTAssertEqual(history[6].dayStartedAt, today)
        XCTAssertEqual(history[6].usedPercent, 0)
    }

    func testDailyUsageHistoryKeepsMissedDaysUnknown() {
        let lastObservedDay = date(year: 2026, month: 8, day: 18)
        let today = date(year: 2026, month: 8, day: 21)
        let history = DailyUsageHistoryTracker.update(
            previous: nil,
            previousDailyUsage: dailyUsageState(
                dayStartedAt: lastObservedDay,
                usedPercent: 36
            ),
            currentDailyUsage: dailyUsageState(dayStartedAt: today, usedPercent: 0),
            at: today,
            calendar: utcCalendar
        )

        XCTAssertEqual(history[3].dayStartedAt, lastObservedDay)
        XCTAssertEqual(history[3].usedPercent, 36)
        XCTAssertNil(history[4].usedPercent)
        XCTAssertNil(history[5].usedPercent)
        XCTAssertEqual(history[6].usedPercent, 0)
    }

    func testDailyUsageHistoryDropsOldDaysAndPreservesValuesAboveOneHundred() {
        let today = date(year: 2026, month: 8, day: 21)
        let previous = [
            DailyUsageDay(
                dayStartedAt: date(year: 2026, month: 8, day: 14),
                usedPercent: 99
            ),
            DailyUsageDay(
                dayStartedAt: date(year: 2026, month: 8, day: 20),
                usedPercent: 120
            )
        ]

        let history = DailyUsageHistoryTracker.update(
            previous: previous,
            previousDailyUsage: nil,
            currentDailyUsage: dailyUsageState(dayStartedAt: today, usedPercent: 4),
            at: today,
            calendar: utcCalendar
        )

        XCTAssertEqual(history.count, 7)
        XCTAssertFalse(history.contains { $0.dayStartedAt == previous[0].dayStartedAt })
        XCTAssertEqual(history[5].usedPercent, 120)
        XCTAssertEqual(history[6].usedPercent, 4)
    }

    func testSnapshotStoreLoadsLegacySnapshotWithoutDailyUsage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let legacyData = Data(
            #"{"fetchedAt":"1970-01-01T00:08:20Z","kind":"percentage","remainingPercent":88,"resetsAt":"1970-01-01T00:16:40Z","schemaVersion":1,"usedPercent":12,"windowDurationMinutes":10080}"#.utf8
        )
        try legacyData.write(
            to: directory.appendingPathComponent(SharedConfiguration.snapshotFilename)
        )

        let snapshot = try UsageSnapshotStore(directory: directory).load()

        XCTAssertEqual(snapshot?.remainingPercent, 88)
        XCTAssertNil(snapshot?.dailyUsage)
        XCTAssertNil(snapshot?.dailyUsageHistory)
    }

    private func dailyUsageState(
        dayStartedAt: Date,
        usedPercent: Double
    ) -> DailyUsageState {
        DailyUsageState(
            dayStartedAt: dayStartedAt,
            segmentInitialRemainingPercent: 100,
            accumulatedBeforeSegmentPercent: 0,
            usedPercent: usedPercent,
            lastRemainingPercent: max(100 - usedPercent, 0),
            lastResetsAt: nil
        )
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        utcCalendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    private func percentageSnapshot(
        remaining: Int,
        fetchedAt: TimeInterval,
        resetsAt: TimeInterval
    ) -> UsageSnapshot {
        UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            kind: .percentage,
            remainingPercent: remaining,
            usedPercent: 100 - Double(remaining),
            windowDurationMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: resetsAt),
            fetchedAt: Date(timeIntervalSince1970: fetchedAt)
        )
    }
}

final class AppServerIntegrationTests: XCTestCase {
    func testReadsLiveCodexRateLimits() async throws {
        guard ProcessInfo.processInfo.environment["RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_CODEX_INTEGRATION_TESTS=1 to query the installed Codex CLI.")
        }

        let located = try await CodexLocator.locate()
        let client = AppServerClient(executableURL: located.executableURL)

        do {
            try await client.start()
            let account = try await client.request(
                method: "account/read",
                params: ["refreshToken": false],
                as: AccountReadResult.self
            )
            XCTAssertEqual(account.account?.type, "chatgpt")

            let result = try await client.request(
                method: "account/rateLimits/read",
                as: RateLimitsReadResult.self
            )
            let snapshot = try UsageSnapshotBuilder.build(from: result)

            XCTAssertNotEqual(snapshot.kind, .unavailable)
            if let remaining = snapshot.remainingPercent {
                XCTAssertTrue((0...100).contains(remaining))
            }
            await client.stop()
        } catch {
            let diagnostics = await client.diagnostics()
            await client.stop()
            XCTFail("\(error.localizedDescription)\n\(diagnostics)")
        }
    }
}
