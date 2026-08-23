import Foundation
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let sampleValues: [Double?] = [12, 34, 8, 63, 41, 77, 18]
        let history = sampleValues.enumerated().map { index, value in
            DailyUsageDay(
                dayStartedAt: calendar.date(
                    byAdding: .day,
                    value: index - (sampleValues.count - 1),
                    to: today
                ) ?? today,
                usedPercent: value
            )
        }

        return UsageEntry(
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
                ),
                dailyUsageHistory: history
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

struct CodexUsageHistoryWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        HStack(spacing: 14) {
            currentUsageSummary
                .frame(width: 108)

            Divider()
                .padding(.vertical, 2)

            historySummary
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            Color.clear
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex Usage History")
        .accessibilityValue(accessibilityValue)
    }

    private var currentUsageSummary: some View {
        VStack(spacing: 0) {
            ZStack {
                UsageRing(progress: remainingProgress, color: outerRingColor, lineWidth: 7)
                    .frame(width: 88, height: 88)

                UsageRing(progress: todayProgress, color: innerRingColor, lineWidth: 7)
                    .frame(width: 70, height: 70)

                VStack(spacing: 0) {
                    Text(todayText)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.65)
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 90)
            .padding(.bottom, 6)

            Text("\(remainingText) Remaining")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var historySummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Last 7 Days")
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(historyDays.enumerated()), id: \.offset) { _, day in
                    UsageHistoryBar(
                        day: day,
                        isToday: Calendar.autoupdatingCurrent.isDate(
                            day.dayStartedAt,
                            inSameDayAs: entry.date
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 5)
            .padding(.bottom, 5)

            statusText
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusText: some View {
        if entry.snapshot?.isStale == true {
            Label("Needs Update", systemImage: "exclamationmark.triangle.fill")
        } else if let resetsAt = entry.snapshot?.resetsAt {
            Text(resetText(for: resetsAt))
        } else {
            Text("Codex Usage")
        }
    }

    private var statusColor: Color {
        entry.snapshot?.isStale == true ? .orange : .secondary
    }

    private var historyDays: [DailyUsageDay] {
        DailyUsageHistoryTracker.update(
            previous: entry.snapshot?.dailyUsageHistory,
            previousDailyUsage: nil,
            currentDailyUsage: entry.snapshot?.dailyUsage,
            at: entry.date
        )
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

    private var accessibilityValue: String {
        let observedDays = historyDays.compactMap { day -> String? in
            guard let usedPercent = day.usedPercent else { return nil }
            return "\(weekdayText(for: day.dayStartedAt)) \(Int(usedPercent.rounded())) percent"
        }
        let history = observedDays.isEmpty
            ? "No recent daily usage data"
            : observedDays.joined(separator: ", ")
        return "\(todayText) used today, \(remainingText) remaining. \(history)"
    }

    private func weekdayText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    private func resetText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: entry.date))"
    }
}

private struct UsageHistoryBar: View {
    let day: DailyUsageDay
    let isToday: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(valueText)
                .font(.system(size: 8, weight: isToday ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isToday ? todayColor : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.primary.opacity(0.06))

                    if let usedPercent = day.usedPercent {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isToday ? todayColor : historyColor)
                            .frame(height: barHeight(for: usedPercent, available: geometry.size.height))
                    }
                }
            }

            Text(day.dayStartedAt, format: .dateTime.weekday(.narrow))
                .font(.system(size: 9, weight: isToday ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isToday ? todayColor : Color.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var valueText: String {
        day.usedPercent.map { "\(Int($0.rounded()))" } ?? "–"
    }

    private var todayColor: Color {
        Color(red: 0.19, green: 0.78, blue: 0.35)
    }

    private var historyColor: Color {
        Color(red: 0.47, green: 0.82, blue: 0.52)
    }

    private func barHeight(for usedPercent: Double, available: CGFloat) -> CGFloat {
        let progress = min(max(usedPercent / 100, 0), 1)
        guard progress > 0 else { return 0 }
        return max(3, available * progress)
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

private struct CodexUsageWidgetFamilyView: View {
    @Environment(\.widgetFamily) private var family

    let entry: UsageEntry

    @ViewBuilder
    var body: some View {
        switch family {
        case .systemMedium:
            CodexUsageHistoryWidgetView(entry: entry)
        default:
            CodexUsageWidgetView(entry: entry)
        }
    }
}

private struct UsageRing: View {
    let progress: Double?
    let color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.1), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
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
            CodexUsageWidgetFamilyView(entry: entry)
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        .configurationDisplayName("Codex Usage")
        .description("Shows today's Codex usage, remaining limit, and seven-day history.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
