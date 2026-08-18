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
            )
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

    func testDailyUsageKeepsAccumulatedValueAcrossLimitReset() {
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
        XCTAssertEqual(afterReset?.usedPercent, 14)
        XCTAssertEqual(afterMoreUsage?.usedPercent, 20)
    }

    func testDailyUsageRestartsOnNextLocalDay() {
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
        XCTAssertEqual(nextDay?.usedPercent, 0)
        XCTAssertEqual(nextDay?.segmentInitialRemainingPercent, 70)
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
