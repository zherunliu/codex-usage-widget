import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.remainingText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Codex Remaining")
                    .foregroundStyle(.secondary)
            }

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(statusColor)

            if let reset = model.snapshot?.resetsAt {
                HStack {
                    Text("Next Reset")
                    Spacer()
                    Text(reset, style: .date)
                    Text(reset, style: .time)
                }
                .font(.caption)
            }

            Divider()

            Button {
                Task { await model.refresh() }
            } label: {
                Label(model.isRefreshing ? "Refreshing…" : "Refresh Now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)

            Button {
                model.chooseCodexExecutable()
            } label: {
                Label("Select Codex CLI…", systemImage: "terminal")
            }

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )

            if !model.codexVersion.isEmpty {
                Divider()
                Text(model.codexVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.codexPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var statusColor: Color {
        switch model.state {
        case .ready:
            return .secondary
        case .failed, .notLoggedIn:
            return .orange
        case .locating, .connecting:
            return .secondary
        }
    }
}
