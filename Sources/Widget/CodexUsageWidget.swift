import Foundation
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(
            date: Date(),
            snapshot: UsageSnapshot(
                schemaVersion: UsageSnapshot.currentSchemaVersion,
                kind: .percentage,
                remainingPercent: 62,
                usedPercent: 38,
                windowDurationMinutes: 10_080,
                resetsAt: Date().addingTimeInterval(2 * 24 * 60 * 60),
                fetchedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snapshot = (try? UsageSnapshotStore().load()) ?? nil
        completion(UsageEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = (try? UsageSnapshotStore().load()) ?? nil
        let entry = UsageEntry(date: Date(), snapshot: snapshot)
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct CodexUsageWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.12), lineWidth: 11)

                if let percent = entry.snapshot?.remainingPercent,
                   entry.snapshot?.kind == .percentage {
                    Circle()
                        .trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(
                            gaugeColor(percent),
                            style: StrokeStyle(lineWidth: 11, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                VStack(spacing: 0) {
                    Text(remainingText)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.7)
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)

            if entry.snapshot?.isStale == true {
                Label("Needs Update", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let resetsAt = entry.snapshot?.resetsAt {
                Text(resetText(for: resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Text("Codex Usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var remainingText: String {
        guard let snapshot = entry.snapshot else { return "--%" }
        switch snapshot.kind {
        case .percentage:
            return snapshot.remainingPercent.map { "\($0)%" } ?? "--%"
        case .unlimited:
            return "∞"
        case .unavailable:
            return "--%"
        }
    }

    private func gaugeColor(_ percent: Int) -> Color {
        switch percent {
        case ..<20:
            return .red
        case ..<50:
            return .orange
        default:
            return .green
        }
    }

    private func resetText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: entry.date))"
    }
}

@main
struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            CodexUsageWidgetView(entry: entry)
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        .configurationDisplayName("Codex Usage")
        .description("Shows the remaining Codex usage for the primary limit.")
        .supportedFamilies([.systemSmall])
    }
}
