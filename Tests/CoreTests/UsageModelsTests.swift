import Foundation
import XCTest

final class UsageModelsTests: XCTestCase {
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
            fetchedAt: Date(timeIntervalSince1970: 500)
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
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
