//
//  AogakuWidgets.swift
//  AogakuWidgets
//
//  Created by shu m on 2025/09/18.
//
import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), snapshot: Self.mock) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> ()) {
        completion(TodayEntry(date: Date(), snapshot: WidgetBridge.load() ?? Self.mock))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> ()) {
        let snap = WidgetBridge.load() ?? Self.mock
        let now = Date()
        let next = nextRefreshDate(basedOn: snap, from: now)
        completion(Timeline(entries: [TodayEntry(date: now, snapshot: snap)], policy: .after(next)))
    }

    private func nextRefreshDate(basedOn snap: WidgetSnapshot, from now: Date) -> Date {
        let cal = Calendar.current
        func time(_ hhmm: String) -> Date? {
            var c = cal.dateComponents([.year,.month,.day], from: now)
            let p = hhmm.split(separator: ":").map { Int($0) ?? 0 }
            c.hour = p[0]; c.minute = p[1]
            return cal.date(from: c)
        }
        for p in snap.periods {
            if let s = time(p.start), s > now { return s.addingTimeInterval(60) }
        }
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!.addingTimeInterval(5 * 60)
    }

    static let mock: WidgetSnapshot = {
        let ps = (0..<5).map { i in
            WidgetPeriod(index: i+1, title: "Course \(i+1)", room: "R\(i+1)",
                         start: PeriodTime.slots[i].start, end: PeriodTime.slots[i].end)
        }
        return WidgetSnapshot(date: Date(), weekday: 5, dayLabel: "木曜日", periods: ps)
    }()
}

struct TodayView: View {
    @Environment(\.widgetFamily) var family
    let entry: TodayEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: medium
            }
        }
        .widgetURL(URL(string: "aogaku://timetable?day=today")) // ← ここに付ける
        .containerBackground(.fill.tertiary, for: .widget)


    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("今日の時間割").font(.headline)
            Text(entry.snapshot.dayLabel).foregroundStyle(.secondary).font(.caption)
        }
    }

    private var small: some View {
        VStack(spacing: 8) {
            header
            if let p = currentPeriod() {
                slotCard(p, highlight: true)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(Text("授業なし").foregroundStyle(.secondary))
            }
        }
        .padding()
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 8) {
                ForEach(entry.snapshot.periods, id: \.index) { p in
                    slotCard(p, highlight: isNow(in: p))
                }
            }
        }
        .padding()
    }

    private func slotCard(_ p: WidgetPeriod, highlight: Bool) -> some View {
        VStack(spacing: 4) {
            Text("\(p.index)").font(.caption).bold()
            Rectangle().frame(height: 3)
                .foregroundStyle(highlight ? .blue : Color.secondary.opacity(0.2))
                .cornerRadius(1.5)
            Text(p.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            Spacer(minLength: 2)
            Text(p.room).font(.caption2).foregroundStyle(.secondary)
            Text("\(p.start)–\(p.end)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(highlight ? Color.blue.opacity(0.12) : Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
        )
    }

    private func isNow(in p: WidgetPeriod) -> Bool {
        let cal = Calendar.current
        let now = Date()
        func time(_ s: String) -> Date {
            var c = cal.dateComponents([.year,.month,.day], from: now)
            let sp = s.split(separator: ":").map { Int($0) ?? 0 }
            c.hour = sp[0]; c.minute = sp[1]
            return cal.date(from: c)!
        }
        return (time(p.start)...time(p.end)).contains(now)
    }

    private func currentPeriod() -> WidgetPeriod? {
        entry.snapshot.periods.first(where: isNow(in:))
    }
}

@main
struct AogakuWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AogakuWidgets", provider: TodayProvider()) { entry in
            TodayView(entry: entry)
        }
        .configurationDisplayName("今日の時間割")
        .description("今日の授業と教室を確認できます。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
