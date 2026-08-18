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
                fetchedAt: Date(),
                dailyUsage: DailyUsageState(
                    dayStartedAt: Calendar.autoupdatingCurrent.startOfDay(for: Date()),
                    segmentInitialRemainingPercent: 80,
                    accumulatedBeforeSegmentPercent: 0,
                    usedPercent: 18,
                    lastRemainingPercent: 62,
                    lastResetsAt: Date().addingTimeInterval(2 * 24 * 60 * 60)
                )
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
        VStack(spacing: 0) {
            ZStack {
                UsageRing(progress: remainingProgress, color: outerRingColor)
                    .frame(width: 96, height: 96)

                UsageRing(progress: todayProgress, color: innerRingColor)
                    .frame(width: 78, height: 78)

                VStack(spacing: 0) {
                    Text(todayText)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.7)
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 98, height: 98)
            .padding(.bottom, 6)

            Text("\(remainingText) Remaining")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.bottom, 2)

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex Usage")
        .accessibilityValue("\(todayText) used today, \(remainingText) remaining")
    }

    private var outerRingColor: Color {
        Color(red: 0.19, green: 0.78, blue: 0.35)
    }

    private var innerRingColor: Color {
        Color(red: 0.47, green: 0.82, blue: 0.52)
    }

    private var remainingProgress: Double? {
        guard entry.snapshot?.kind == .percentage,
              let percent = entry.snapshot?.remainingPercent else {
            return nil
        }
        return min(max(Double(percent) / 100, 0), 1)
    }

    private var todayUsage: Double? {
        guard let usage = entry.snapshot?.dailyUsage,
              usage.isCurrentDay(at: entry.date) else {
            return nil
        }
        return max(usage.usedPercent, 0)
    }

    private var todayProgress: Double? {
        todayUsage.map { min($0 / 100, 1) }
    }

    private var todayText: String {
        todayUsage.map { "\(Int($0.rounded()))%" } ?? "--%"
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

    private func resetText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: entry.date))"
    }
}

private struct UsageRing: View {
    let progress: Double?
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.1), lineWidth: 8)

            if let progress {
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
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
        .description("Shows today's Codex usage and the remaining primary limit.")
        .supportedFamilies([.systemSmall])
    }
}
