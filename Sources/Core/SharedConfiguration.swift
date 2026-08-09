import Foundation

enum SharedConfiguration {
    static let snapshotFilename = "usage-snapshot.json"

    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "com.local.CodexUsage.shared"
    }
}

struct UsageSnapshotStore {
    enum StoreError: LocalizedError {
        case incompatibleSchema

        var errorDescription: String? {
            "The usage cache schema is incompatible."
        }
    }

    private let fileManager: FileManager
    private let explicitDirectory: URL?

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.explicitDirectory = directory
    }

    func load() throws -> UsageSnapshot? {
        let url = try snapshotURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let snapshot = try JSONDecoder.codexUsage.decode(
            UsageSnapshot.self,
            from: Data(contentsOf: url)
        )
        guard snapshot.schemaVersion == UsageSnapshot.currentSchemaVersion else {
            throw StoreError.incompatibleSchema
        }
        return snapshot
    }

    func save(_ snapshot: UsageSnapshot) throws {
        let url = try snapshotURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.codexUsage.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func remove() throws {
        let url = try snapshotURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func snapshotURL() throws -> URL {
        if let explicitDirectory {
            return explicitDirectory.appendingPathComponent(SharedConfiguration.snapshotFilename)
        }

        if let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfiguration.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(SharedConfiguration.snapshotFilename)
        }

        let fallback = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return fallback
            .appendingPathComponent("CodexUsage", isDirectory: true)
            .appendingPathComponent(SharedConfiguration.snapshotFilename)
    }
}

private extension JSONEncoder {
    static var codexUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var codexUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
