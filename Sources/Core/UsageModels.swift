import Foundation

enum UsageKind: String, Codable, Equatable {
    case percentage
    case unlimited
    case unavailable
}

struct UsageSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let kind: UsageKind
    let remainingPercent: Int?
    let usedPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
    let fetchedAt: Date
    let dailyUsage: DailyUsageState?
    let dailyUsageHistory: [DailyUsageDay]?

    init(
        schemaVersion: Int,
        kind: UsageKind,
        remainingPercent: Int?,
        usedPercent: Double?,
        windowDurationMinutes: Int?,
        resetsAt: Date?,
        fetchedAt: Date,
        dailyUsage: DailyUsageState? = nil,
        dailyUsageHistory: [DailyUsageDay]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
        self.dailyUsage = dailyUsage
        self.dailyUsageHistory = dailyUsageHistory
    }

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 30 * 60
    }

    static func unavailable(at date: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            schemaVersion: currentSchemaVersion,
            kind: .unavailable,
            remainingPercent: nil,
            usedPercent: nil,
            windowDurationMinutes: nil,
            resetsAt: nil,
            fetchedAt: date
        )
    }

    func withUsageTracking(
        dailyUsage: DailyUsageState?,
        dailyUsageHistory: [DailyUsageDay]
    ) -> UsageSnapshot {
        UsageSnapshot(
            schemaVersion: schemaVersion,
            kind: kind,
            remainingPercent: remainingPercent,
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            dailyUsage: dailyUsage,
            dailyUsageHistory: dailyUsageHistory
        )
    }
}

struct DailyUsageState: Codable, Equatable {
    let dayStartedAt: Date
    let segmentInitialRemainingPercent: Double
    let accumulatedBeforeSegmentPercent: Double
    let usedPercent: Double
    let lastRemainingPercent: Double
    let lastResetsAt: Date?

    func isCurrentDay(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.isDate(dayStartedAt, inSameDayAs: date)
    }
}

struct DailyUsageDay: Codable, Equatable {
    let dayStartedAt: Date
    let usedPercent: Double?
}

enum DailyUsageTracker {
    static func update(
        previous: DailyUsageState?,
        with snapshot: UsageSnapshot,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DailyUsageState? {
        guard snapshot.kind == .percentage,
              let remainingPercent = snapshot.remainingPercent else {
            guard let previous,
                  previous.isCurrentDay(at: snapshot.fetchedAt, calendar: calendar) else {
                return nil
            }
            return previous
        }

        let remaining = min(max(Double(remainingPercent), 0), 100)
        let dayStartedAt = calendar.startOfDay(for: snapshot.fetchedAt)

        guard let previous,
              previous.isCurrentDay(at: snapshot.fetchedAt, calendar: calendar) else {
            return DailyUsageState(
                dayStartedAt: dayStartedAt,
                segmentInitialRemainingPercent: remaining,
                accumulatedBeforeSegmentPercent: 0,
                usedPercent: 0,
                lastRemainingPercent: remaining,
                lastResetsAt: snapshot.resetsAt
            )
        }

        if didReset(previous: previous, snapshot: snapshot, remaining: remaining) {
            return DailyUsageState(
                dayStartedAt: previous.dayStartedAt,
                segmentInitialRemainingPercent: remaining,
                accumulatedBeforeSegmentPercent: previous.usedPercent,
                usedPercent: previous.usedPercent,
                lastRemainingPercent: remaining,
                lastResetsAt: snapshot.resetsAt ?? previous.lastResetsAt
            )
        }

        let segmentUsed = max(previous.segmentInitialRemainingPercent - remaining, 0)
        let candidate = previous.accumulatedBeforeSegmentPercent + segmentUsed
        let used = max(previous.usedPercent, candidate)

        return DailyUsageState(
            dayStartedAt: previous.dayStartedAt,
            segmentInitialRemainingPercent: previous.segmentInitialRemainingPercent,
            accumulatedBeforeSegmentPercent: previous.accumulatedBeforeSegmentPercent,
            usedPercent: used,
            lastRemainingPercent: remaining,
            lastResetsAt: snapshot.resetsAt ?? previous.lastResetsAt
        )
    }

    private static func didReset(
        previous: DailyUsageState,
        snapshot: UsageSnapshot,
        remaining: Double
    ) -> Bool {
        if let previousReset = previous.lastResetsAt,
           let currentReset = snapshot.resetsAt,
           currentReset.timeIntervalSince(previousReset) > 1 {
            return true
        }

        let remainingIncreased = remaining > previous.lastRemainingPercent
        if let previousReset = previous.lastResetsAt,
           snapshot.fetchedAt >= previousReset,
           remainingIncreased {
            return true
        }

        return previous.lastResetsAt == nil
            && snapshot.resetsAt == nil
            && remainingIncreased
    }
}

enum DailyUsageHistoryTracker {
    static let capacity = 7

    static func update(
        previous: [DailyUsageDay]?,
        previousDailyUsage: DailyUsageState?,
        currentDailyUsage: DailyUsageState?,
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [DailyUsageDay] {
        let today = calendar.startOfDay(for: date)
        let days = (-(capacity - 1)...0).map { offset in
            day(byAdding: offset, to: today, calendar: calendar)
        }
        let validDays = Set(days)
        var usageByDay: [Date: Double] = [:]

        for item in previous ?? [] {
            let day = calendar.startOfDay(for: item.dayStartedAt)
            guard validDays.contains(day), let usedPercent = item.usedPercent else {
                continue
            }
            store(usedPercent, for: day, in: &usageByDay)
        }

        store(previousDailyUsage, validDays: validDays, calendar: calendar, in: &usageByDay)
        store(currentDailyUsage, validDays: validDays, calendar: calendar, in: &usageByDay)

        return days.map { day in
            DailyUsageDay(dayStartedAt: day, usedPercent: usageByDay[day])
        }
    }

    private static func store(
        _ state: DailyUsageState?,
        validDays: Set<Date>,
        calendar: Calendar,
        in usageByDay: inout [Date: Double]
    ) {
        guard let state else { return }
        let day = calendar.startOfDay(for: state.dayStartedAt)
        guard validDays.contains(day) else { return }
        store(state.usedPercent, for: day, in: &usageByDay)
    }

    private static func store(
        _ usedPercent: Double,
        for day: Date,
        in usageByDay: inout [Date: Double]
    ) {
        let value = max(usedPercent, 0)
        usageByDay[day] = max(usageByDay[day] ?? 0, value)
    }

    private static func day(
        byAdding offset: Int,
        to date: Date,
        calendar: Calendar
    ) -> Date {
        let adjusted = calendar.date(byAdding: .day, value: offset, to: date)
            ?? date.addingTimeInterval(Double(offset) * 24 * 60 * 60)
        return calendar.startOfDay(for: adjusted)
    }
}

struct AccountReadResult: Decodable {
    struct Account: Decodable {
        let type: String
        let planType: String?
    }

    let account: Account?
    let requiresOpenaiAuth: Bool
}

struct RateLimitsReadResult: Decodable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
}

struct RateLimitBucket: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: TimeInterval?
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
    }

    let primary: Window?
    let credits: Credits?
    let rateLimitReachedType: String?
}

enum UsageSnapshotBuilder {
    enum BuildError: LocalizedError {
        case missingCodexBucket

        var errorDescription: String? {
            switch self {
            case .missingCodexBucket:
                return "Codex did not return a primary usage limit."
            }
        }
    }

    static func build(
        from result: RateLimitsReadResult,
        fetchedAt: Date = Date()
    ) throws -> UsageSnapshot {
        guard let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits else {
            throw BuildError.missingCodexBucket
        }

        if bucket.credits?.unlimited == true {
            return UsageSnapshot(
                schemaVersion: UsageSnapshot.currentSchemaVersion,
                kind: .unlimited,
                remainingPercent: nil,
                usedPercent: bucket.primary?.usedPercent,
                windowDurationMinutes: bucket.primary?.windowDurationMins,
                resetsAt: bucket.primary?.resetsAt.map(Date.init(timeIntervalSince1970:)),
                fetchedAt: fetchedAt
            )
        }

        guard let window = bucket.primary else {
            return .unavailable(at: fetchedAt)
        }

        let clampedUsed = min(max(window.usedPercent, 0), 100)
        let remaining = bucket.rateLimitReachedType == nil
            ? Int((100 - clampedUsed).rounded())
            : 0

        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            kind: .percentage,
            remainingPercent: remaining,
            usedPercent: clampedUsed,
            windowDurationMinutes: window.windowDurationMins,
            resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)),
            fetchedAt: fetchedAt
        )
    }
}
