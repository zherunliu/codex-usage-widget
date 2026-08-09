import Foundation

struct LocatedCodex: Equatable {
    let executableURL: URL
    let version: String
}

enum CodexLocator {
    enum LocatorError: LocalizedError {
        case notFound
        case versionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Codex CLI was not found. Select the codex executable manually."
            case .versionFailed(let message):
                return "Unable to read the Codex version: \(message)"
            }
        }
    }

    static func locate(savedPath: String? = nil) async throws -> LocatedCodex {
        var candidates: [URL] = []
        if let savedPath, !savedPath.isEmpty {
            candidates.append(URL(fileURLWithPath: savedPath))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".local/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append(
                    URL(fileURLWithPath: String(directory))
                        .appendingPathComponent("codex")
                )
            }
        }

        var seen = Set<String>()
        for candidate in candidates {
            let stableURL = candidate.standardizedFileURL
            let resolvedPath = stableURL.resolvingSymlinksInPath().path
            guard seen.insert(resolvedPath).inserted else { continue }
            guard FileManager.default.isExecutableFile(atPath: stableURL.path) else { continue }
            let version = try await version(at: stableURL)
            return LocatedCodex(executableURL: stableURL, version: version)
        }

        throw LocatorError.notFound
    }

    static func validate(url: URL) async throws -> LocatedCodex {
        let stableURL = url.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: stableURL.path) else {
            throw LocatorError.notFound
        }
        return LocatedCodex(
            executableURL: stableURL,
            version: try await version(at: stableURL)
        )
    }

    private static func version(at url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = url
            process.arguments = ["--version"]
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw LocatorError.versionFailed(error.localizedDescription)
            }

            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: stderr, encoding: .utf8) ?? "Unknown error"
                throw LocatorError.versionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let text = String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else {
                throw LocatorError.versionFailed("Version output is empty")
            }
            return text
        }.value
    }
}
