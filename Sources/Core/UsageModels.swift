import Foundation

enum UsageKind: String, Codable, Equatable {
    case percentage
    case unlimited
    case unavailable
}

struct UsageSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let kind: UsageKind
    let remainingPercent: Int?
    let usedPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
    let fetchedAt: Date

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
