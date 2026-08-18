import AppKit
import Foundation
import ServiceManagement
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    enum AppState: Equatable {
        case locating
        case connecting
        case ready
        case notLoggedIn
        case failed(String)
    }

    @Published private(set) var state: AppState = .locating
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var codexPath = ""
    @Published private(set) var codexVersion = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var launchAtLoginEnabled = false

    private let store = UsageSnapshotStore()
    private var client: AppServerClient?
    private var currentCodex: LocatedCodex?
    private var schedulerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var hasStarted = false

    init() {
        snapshot = try? store.load()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        Task { [weak self] in
            await self?.start()
        }
    }

    var statusText: String {
        switch state {
        case .locating:
            return "Locating Codex…"
        case .connecting:
            return "Connecting to Codex…"
        case .ready:
            return snapshot?.isStale == true ? "Usage needs refresh" : "Connected"
        case .notLoggedIn:
            return "Run codex login first"
        case .failed(let message):
            return message
        }
    }

    var remainingText: String {
        guard let snapshot else { return "--%" }
        switch snapshot.kind {
        case .percentage:
            return snapshot.remainingPercent.map { "\($0)%" } ?? "--%"
        case .unlimited:
            return "∞"
        case .unavailable:
            return "--%"
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        state = .locating

        do {
            let savedPath = UserDefaults.standard.string(forKey: "codexExecutablePath")
            let located = try await CodexLocator.locate(savedPath: savedPath)
            try await connect(to: located)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard !isRefreshing, let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let account = try await client.request(
                method: "account/read",
                params: ["refreshToken": false],
                as: AccountReadResult.self
            )

            guard let account = account.account else {
                state = .notLoggedIn
                return
            }
            guard account.type == "chatgpt" else {
                state = .failed("Codex is authenticated with an API key. ChatGPT usage is unavailable.")
                return
            }

            let result = try await client.request(
                method: "account/rateLimits/read",
                as: RateLimitsReadResult.self
            )
            let fetchedSnapshot = try UsageSnapshotBuilder.build(from: result)
            let dailyUsage = DailyUsageTracker.update(
                previous: snapshot?.dailyUsage,
                with: fetchedSnapshot
            )
            let newSnapshot = fetchedSnapshot.withDailyUsage(dailyUsage)
            try store.save(newSnapshot)
            snapshot = newSnapshot
            state = .ready
            WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Select Codex CLI"
        panel.message = "Choose the codex executable."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let located = try await CodexLocator.validate(url: url)
                UserDefaults.standard.set(located.executableURL.path, forKey: "codexExecutablePath")
                reconnectTask?.cancel()
                reconnectTask = nil
                try await connect(to: located)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            state = .failed("Unable to update Launch at Login: \(error.localizedDescription)")
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func connect(to located: LocatedCodex) async throws {
        schedulerTask?.cancel()
        if let client {
            await client.stop()
        }
        client = nil

        codexPath = located.executableURL.path
        codexVersion = located.version
        currentCodex = located
        state = .connecting

        let newClient = AppServerClient(executableURL: located.executableURL)
        await newClient.setNotificationHandler { [weak self] method in
            Task { @MainActor in
                await self?.handleRuntimeNotification(method)
            }
        }
        try await newClient.start()
        client = newClient
        reconnectAttempt = 0
        await refresh()

        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func handleRuntimeNotification(_ method: String) async {
        switch method {
        case "account/rateLimits/updated":
            await refresh()
        case "internal/processExited":
            client = nil
            scheduleReconnect()
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let currentCodex else { return }

        let delays: [Duration] = [
            .seconds(1), .seconds(2), .seconds(4),
            .seconds(8), .seconds(30), .seconds(60)
        ]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        state = .failed("Codex exited. Reconnecting…")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil

            do {
                let located = try await CodexLocator.validate(url: currentCodex.executableURL)
                try await self.connect(to: located)
            } catch {
                self.state = .failed("Reconnection failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }
}
