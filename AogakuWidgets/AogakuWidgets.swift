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
        // テスト用の教員名
        let teachers = ["T1", "T2", "T3", "T4", "T5"]
        let ps = (0..<5).map { i in
            WidgetPeriod(index: i+1, title: "Course \(i+1)", room: "R\(i+1)",
                         start: PeriodTime.slots[i].start, end: PeriodTime.slots[i].end, teacher: teachers[i] )
        }
        return WidgetSnapshot(date: Date(), weekday: 5, dayLabel: "木曜日", periods: [
            .init(index: 1, title: "Course 1", room: "R1", start: "09:00", end: "10:30", teacher: "T1"),
            .init(index: 2, title: "Course 2", room: "R2", start: "10:45", end: "12:15", teacher: "T2"),
            .init(index: 3, title: "Course 3", room: "R3", start: "13:20", end: "14:50", teacher: "T3"),
            .init(index: 4, title: "Course 4", room: "R4", start: "15:05", end: "16:35", teacher: "T4"),
            .init(index: 5, title: "Course 5", room: "R5", start: "16:50", end: "18:20", teacher: "T5"),
        ])
    }()
}


struct TodayView: View {
    @Environment(\.widgetFamily) var family
    let entry: TodayEntry
    
    // その日の実データから「見せる最終限」を決める（最低5、最大7）
    private func lastActivePeriod(limit: Int = 7) -> Int {
        // タイトル/教室/教師のどれかが入っていれば「授業あり」
        func hasAny(_ p: WidgetPeriod) -> Bool {
            if !p.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if !p.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            let t = teacher(of: p) // ← ここは String
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return false
        }

        let last = entry.snapshot.periods
            .sorted { $0.index < $1.index }
            .last(where: { hasAny($0) })?.index ?? 5

        return min(max(last, 5), limit)   // 最低5、最大7
    }
    
    var body: some View {
        switch family {
        case .systemSmall:
            smallList()                      // ← 小サイズは“時限＋授業名”のみ
                .widgetURL(URL(string: "aogaku://timetable?day=today"))
        case .systemMedium:
            GeometryReader { geo in
                // 表示するコマ数（5〜7を自動）
                let columns = lastActivePeriod()

                // 👉 余白と間隔をタイトに
                let outerX: CGFloat = 2                       // 左右の外側余白（小さく）
                
                // ← セル同士のすき間。この値を下げる
                let spacing: CGFloat = (columns >= 7) ? 2 //// 7限ならさらに詰める
                                        : (columns == 6 ? 2 : 4)// 6限/5限
                //let spacing: CGFloat = (columns >= 7) ? 4
                          //           : (columns == 6 ? 6 : 8)

                // 幅計算は “表示領域 − 左右余白 − すき間合計”
                let usable = geo.size.width - outerX*2 - CGFloat(columns - 1) * spacing
                let cellW  = usable / CGFloat(columns)
                let cellH  = geo.size.height * 0.82           // 少し背を高く

                VStack(alignment: .leading, spacing: 4) {
                    Text("今日の時間割")
                        .font(.headline)

                    HStack(spacing: spacing) {
                        ForEach(entry.snapshot.periods.prefix(columns), id: \.self) { p in
                            slotCard(p, highlight: isNow(in: p))
                                .frame(width: cellW, height: cellH)
                                .clipped()
                        }
                    }
                }
                .padding(.top, 5)
                .padding(.horizontal, outerX)                 // ← 計算と同じ値を使う
                .padding(.bottom, 4)
                .widgetURL(URL(string: "aogaku://timetable?day=today"))
            }

            
        case .systemLarge:
            largeDetail()// ⬅︎ これを追加
                .widgetURL(URL(string: "aogaku://timetable?day=today"))
        default:
            // その他のサイズは medium と同等にしておく
            medium
        }
    }
    // large 用：曜日だけ表示するヘッダー
    private var largeWeekdayHeader: some View {
        Text(entry.snapshot.dayLabel)
            .font(.caption)                  // 小さめ
            .foregroundStyle(.secondary)     // 薄めの色
    }

    
    // === 小サイズ用：時限＋授業名のみ ===
    private func smallList() -> some View {
        // 1〜5限のタイトルを縦に並べる。未登録は "−" を表示
        VStack(alignment: .leading, spacing: 8) {
            // 小ウィジェットには見出しは入れず、本文を最大化
            ForEach(1...5, id: \.self) { i in
                let title = entry.snapshot.periods.first(where: { $0.index == i })?.title ?? "−"
                HStack(spacing: 10) {
                    Text("\(i)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 14, alignment: .trailing)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if i < 5 { Divider().opacity(0.25) }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Large (詳細リスト)
    // MARK: - Large (詳細リスト)
    // === Large（詳細リスト）: 画面内に確実に収める版 ===
    @ViewBuilder
    private func largeDetail() -> some View {
        GeometryReader { geo in
            // 1...rows まで表示（最大 7 限を想定）
            let rows = max(5, min(7, entry.snapshot.periods.map { $0.index }.max() ?? 5))

            // レイアウト定数（必要なら微調整）
            let topInset: CGFloat = 6                  // 上マージン
            let headerHeight: CGFloat = 20             // 「木曜日」ラベルの想定高さ
            let gapHeaderToList: CGFloat = 4           // 見出しとリストの間
            let rowSpacing: CGFloat = (rows >= 7 ? 3 : 5)

            // 利用可能な高さから、行間と見出し分を引いて行高を割り出す
            let usable = geo.size.height
                      - topInset - headerHeight - gapHeaderToList
                      - CGFloat(rows - 1) * rowSpacing
            let rowH = floor(usable / CGFloat(rows))   // 端数切り捨てでオーバー防止

            // 余り分を下に回して、下が切れないようにする
            let consumed = topInset + headerHeight + gapHeaderToList
                         + rowH * CGFloat(rows) + CGFloat(rows - 1) * rowSpacing
            let bottomInset = max(0, geo.size.height - consumed)

            VStack(alignment: .leading, spacing: gapHeaderToList) {
                // 見出しは曜日だけ
                Text(entry.snapshot.dayLabel)
                    .font(.headline)

                VStack(spacing: rowSpacing) {
                    ForEach(1...rows, id: \.self) { i in
                        let p = entry.snapshot.periods.first { $0.index == i }
                        largeRow(index: i,
                                 period: p,
                                 highlight: p.map(isNow(in:)) ?? false, height: rowH)
                            .frame(height: rowH)      // ← 計算した行高を適用
                    }
                }
            }
            .padding(.top, topInset)
            .padding(.horizontal, 12)
            .padding(.bottom, bottomInset)
        }
    }

    // 余り用のピル（任意）
    @ViewBuilder
    private func morePill(count: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            Text("+\(count)").font(.headline).foregroundStyle(.secondary)
        }
    }

    
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    
    @ViewBuilder
    private func slotCard(_ p: WidgetPeriod, highlight: Bool) -> some View {
        ZStack { // 背景と内容を確実に同寸へ
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlight ? Color(.systemFill) : Color(.tertiarySystemFill))

            VStack(spacing: 4) {
                // コマ番号
                Text("\(p.index)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(highlight ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                // 授業名（最大2行）
                Text(p.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                // 教室（1行）
                Text(p.room)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .center)

                // 時間（等幅数字）
                Text("\(p.start)–\(p.end)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // ← 内部を均一に
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(highlight ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
    
    @ViewBuilder
    private func largeRow(index: Int, period: WidgetPeriod?, highlight: Bool, height: CGFloat) -> some View {
        // 未登録時の安全値
        let start = period?.start ?? PeriodTime.slots[index-1].start
        let end   = period?.end   ?? PeriodTime.slots[index-1].end
        let title = period?.title ?? "−"
        let room  = period?.room  ?? "−"
        let teacherName = teacher(of: period)

        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlight ? Color.accentColor.opacity(0.10)
                                : Color(.secondarySystemBackground))

            HStack(spacing: 10) {
                // 左：時限と時間（幅細め）
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(start).font(.caption2.monospacedDigit())
                    Text(end).font(.caption2.monospacedDigit())
                }
                .frame(width: 58, alignment: .leading)

                // 中央：授業名 + サブ情報（1行で揃える）
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    HStack(spacing: 10) {
                        Text(room)
                        if !teacherName.isEmpty { Text(teacherName) }
                    }
                    .font(.caption)                 // ← 少し小さめ
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            //.padding(.vertical, 6)
            .frame(height: height)                  // ← 行高を固定
        }
    }


    /// WidgetPeriod に teacher プロパティが無い環境でもビルドを通すためのフォールバック
    private func teacher(of p: WidgetPeriod?) -> String {
        guard let p else { return "" }
        if let t = Mirror(reflecting: p).children.first(where: { $0.label == "teacher" })?.value as? String {
            return t
        }
        return ""
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
        let base = StaticConfiguration(kind: "AogakuWidgets",
                                       provider: TodayProvider()) { entry in
            let view = TodayView(entry: entry)
            if #available(iOSApplicationExtension 17.0, *) {
                view.containerBackground(for: .widget) { Color.clear }
            } else {
                view
            }
        }
        .configurationDisplayName("今日の時間割")
        .description("今日の授業や教室、教員名まで確認できます。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge]) // ⬅︎ large 追加

        if #available(iOSApplicationExtension 17.0, *) {
            return base.contentMarginsDisabled()
        } else {
            return base
        }
    }
}

