//
//  AogakuWidgets.swift
//  AogakuWidgets
//
//  Created by shu m on 2025/09/18.
//
import WidgetKit
import SwiftUI

private let APP_GROUP_ID = "group.jp.forta.Aogaku"

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// App Group から“今日の列”を組み立てる（丸めない・設定を尊重）
private func buildTodayFromShared() -> WidgetSnapshot? {
    guard let g = UserDefaults(suiteName: APP_GROUP_ID),
          let term = g.string(forKey: "tt.term"),
          let data = g.data(forKey: "tt.assigned.\(term)") else { return nil }

    struct ACourse: Codable { let id: String?; let title: String; let room: String; let teacher: String? }
    guard let arr = try? JSONDecoder().decode([ACourse?].self, from: data) else { return nil }

    let days    = max(1, g.integer(forKey: "tt.days"))            // 5 or 6
    let periods = max(1, g.integer(forKey: "tt.periods"))
    let colors  = (g.dictionary(forKey: "tt.colors") as? [String:String]) ?? [:]
    let includeSaturday = (g.object(forKey: "tt.includeSaturday") as? Bool) ?? (days >= 6)

    let now = Date()
    let cal = Calendar.current
    let wk  = cal.component(.weekday, from: now)   // 1=Sun ... 7=Sat
    let dayIdx = (wk + 5) % 7                      // 0=Mon ... 5=Sat

    // 日付ラベル
    let df = DateFormatter(); df.locale = Locale(identifier: "ja_JP")
    df.setLocalizedDateFormatFromTemplate("EEEE")
    let dayLabel = df.string(from: now)

    // 授業なし（空）スナップショットを作る
    func emptySnapshot() -> WidgetSnapshot {
        var ps: [WidgetPeriod] = []
        for p in 1...min(periods, PeriodTime.slots.count) {
            let slot = PeriodTime.slots[p-1]
            ps.append(.init(index: p, title: " ", room: "", start: slot.start, end: slot.end, teacher: "", colorKey: nil))
        }
        return .init(date: now, weekday: wk, dayLabel: dayLabel, periods: ps)
    }

    // ★ 分岐：日曜は常に、土曜＋平日のみ設定の時は「授業なし」
    if wk == 1 { return emptySnapshot() }                  // Sunday
    if dayIdx == 5 && !includeSaturday { return emptySnapshot() }  // Saturday but 5日設定

    // それ以外は“丸めず”にその日の列をそのまま使う
    var ps: [WidgetPeriod] = []
    for p in 1...min(periods, PeriodTime.slots.count) {
        let idx = (p - 1) * days + dayIdx        // ← 丸めない
        let c   = (arr.indices.contains(idx) ? arr[idx] : nil)
        let slot = PeriodTime.slots[p-1]
        let colorKey = colors["cells.d\(dayIdx)p\(p)"]
        ps.append(.init(index: p,
                        title: c?.title ?? " ",
                        room:  c?.room ?? "",
                        start: slot.start, end: slot.end,
                        teacher: c?.teacher ?? "",
                        colorKey: colorKey))
    }
    return .init(date: now, weekday: wk, dayLabel: dayLabel, periods: ps)
}



struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), snapshot: Self.mock) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> ()) {
        completion(TodayEntry(date: Date(), snapshot: WidgetBridge.load() ?? Self.mock))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> ()) {
        // まず共有から“今日”を生成。無ければ従来の保存スナップショットにフォールバック
        let snap = buildTodayFromShared() ?? (WidgetBridge.load() ?? Self.mock)

        let now  = Date()
        let cal  = Calendar.current

        // 次回更新は「各コマ開始の1分後」か「翌日0:05」の早い方
        func time(_ hhmm: String) -> Date? {
            var c = cal.dateComponents([.year,.month,.day], from: now)
            let p = hhmm.split(separator: ":").map { Int($0) ?? 0 }
            c.hour = p[0]; c.minute = p[1]
            return cal.date(from: c)
        }
        let nextClass = snap.periods.compactMap { time($0.start) }.first { $0 > now }?.addingTimeInterval(60)
        let nextDay   = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!.addingTimeInterval(5*60)
        let next = min(nextClass ?? nextDay, nextDay)

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
        let colors   = ["blue", "green", "yellow", "red", "teal", "gray"] // ここは好きな並びで
        let ps = (0..<5).map { i in
            WidgetPeriod(index: i+1, title: "Course \(i+1)", room: "R\(i+1)",
                         start: PeriodTime.slots[i].start, end: PeriodTime.slots[i].end, teacher: teachers[i], colorKey: colors[i] )
        }
        return WidgetSnapshot(date: Date(), weekday: 5, dayLabel: "木曜日", periods: [
            .init(index: 1, title: "Course 1", room: "R1", start: "09:00", end: "10:30", teacher: "T1", colorKey: "colors"),
            .init(index: 2, title: "Course 2", room: "R2", start: "10:45", end: "12:15", teacher: "T2", colorKey: "colors"),
            .init(index: 3, title: "Course 3", room: "R3", start: "13:20", end: "14:50", teacher: "T3", colorKey: "colors"),
            .init(index: 4, title: "Course 4", room: "R4", start: "15:05", end: "16:35", teacher: "T4", colorKey: "colors"),
            .init(index: 5, title: "Course 5", room: "R5", start: "16:50", end: "18:20", teacher: "T5", colorKey: "colors"),
        ])
    }()
}




// Widgetの背景色（system / lightGray / white に対応）
private func widgetBGColor() -> Color {
    // App Group 未設定でも動くよう、とりあえず "lightGray" を既定に
    let pref = (UserDefaults(suiteName: "group.jp.forta.Aogaku")?
                .string(forKey: "timetable.bg")) ?? "lightGray"
    switch pref {
    case "white":
        return .white
    case "system":
        return Color(.systemBackground)
    default:
        // ダーク= #1F1F1F 付近 / ライト= ほぼ白グレー
        return Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor(white: 0.20, alpha: 1.0)
            : UIColor(white: 0.96, alpha: 1.0)
        })
    }
}

// secondary より少しだけ濃いダイナミックグレー
private let weekdayTint = Color(UIColor { trait in
    if trait.userInterfaceStyle == .dark {
        // ダークでは白系をやや強め（≒濃く）に
        return UIColor(white: 1.0, alpha: 0.80)
    } else {
        // ライトでは黒系をやや強め（≒濃く）に
        return UIColor(white: 0.0, alpha: 0.60)
    }
})

private func uiColor(for key: String?) -> UIColor {
    switch key {
    case "blue":   return .systemBlue
    case "green":  return .systemGreen
    case "yellow": return .systemYellow
    case "red":    return .systemRed
    case "teal":   return .systemTeal
    case "gray":   return .systemGray
    default:       return UIColor.systemTeal // 未設定時は既存と同じグレー系
    }
}
// 追加：パステル化（白を混ぜる）
private func pastel(_ c: UIColor, ratio: CGFloat = 0.6) -> UIColor {
    let r = max(0, min(1, ratio))
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    guard c.getRed(&r1, green: &g1, blue: &b1, alpha: &a1) else { return c }
    return UIColor(red: r1*(1-r) + r,
                   green: g1*(1-r) + r,
                   blue: b1*(1-r) + r,
                   alpha: a1)
}

// === Font tuning for medium widget ===
private enum WFont {
    static let titleSize: CGFloat = 12   // 既存 17 → 12 に
    static let timeSize:  CGFloat = 9   // 開始/終了時刻の数字を少し小さく
    static let indexFont: Font = .footnote.weight(.semibold)  // 見出しの 1〜5 も小さく
    static let roomSize:  CGFloat = 10  // ← 教室（例: 1111, B304 など）
    static let weekdayFont: Font = .system(size: 12, weight: .semibold) // ← 追加：曜日
    // 追加：Large 向けの時限番号フォント
    static let largeIndexSize: CGFloat = 13
    static let largeTimeSize: CGFloat = 10 // ← Large 用の開始/終了（既存の .caption2 より少し小さめ）
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
    // TodayView の中に追加
    private func isNoClassDay() -> Bool {
        let cal = Calendar.current
        let wk = cal.component(.weekday, from: entry.date) // 1=Sun...7=Sat
        if wk == 1 { return true }                         // 日曜は常に「授業なし」

        // すべて空（空白のみ含む）なら授業なし判定
        return entry.snapshot.periods.allSatisfy {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            teacher(of: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private func noClassView() -> some View {
        VStack(spacing: 4) {
            Text(entry.snapshot.dayLabel)
                .font(.caption2).opacity(0.6)
            Text("今日の授業はありません")
                .font(family == .systemSmall ? .caption2 : .headline)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        if isNoClassDay() {
            noClassView()
        } else {
            switch family {
            case .systemSmall:
                smallList().widgetURL(URL(string: "aogaku://timetable?day=today"))
            case .systemMedium:
                mediumStrip().widgetURL(URL(string: "aogaku://timetable?day=today"))
            case .systemLarge:
                largeDetail().widgetURL(URL(string: "aogaku://timetable?day=today"))
            default:
                mediumStrip()
            }
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
                let nowHere = isNowSlot(i)            // ← 追加：今この時限かどうか
                HStack(spacing: 10) {
                    Text("\(i)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(nowHere ? Color.blue : .gray) // ← 今の時限だけ青
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

    // MARK: - Medium（画像の見た目）
    private func mediumStrip() -> some View {
        GeometryReader { geo in
            let columns = lastActivePeriod(limit: 7)      // 5〜7コマまで自動
            let outerX: CGFloat = 2                      // 左右余白
            let spacing: CGFloat = (columns >= 7) ? 3 : 3 // コマ間のすき間をやや詰め

            // 高さ配分を先に決めて「確実に収める」
            let dayLabelH: CGFloat = 18                   // 曜日ラベルの高さ
            let timeHeaderH: CGFloat = 28                // 「9:00 / 1 / 10:30」の高さ（小さめ）
            let dotH: CGFloat = 10                        // 下の丸インジケータ
            let verticalGaps: CGFloat = 2 + 2            // VStack間の余白（上4 + 下6）

            // 使える高さ ＝ 全体 − ヘッダー類
            let usableH = geo.size.height - dayLabelH - timeHeaderH - dotH - verticalGaps
            let cardH   = max(usableH, 44)                // 安全値

            // セル幅（左右余白・コマ間スペースを引いて等分）
            let usableW = geo.size.width - outerX*2 - CGFloat(columns-1)*spacing
            let cellW   = floor(usableW / CGFloat(columns))

            VStack(spacing: 2) {                          // ← 上余白を詰める
                // 上：曜日を中央に
                Text(entry.snapshot.dayLabel)
                    .font(WFont.weekdayFont)     // ← ここだけでサイズ調整できる
                    .foregroundStyle(weekdayTint)
                    .padding(.top, 4)   // 曜日だけ少し下げる
                    .frame(maxWidth: .infinity, alignment: .center)

                // 列
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(1...columns, id: \.self) { i in
                        let p = entry.snapshot.periods.first { $0.index == i }
                        let nowHere = p.map(isNow(in:)) ?? isNowSlot(i)

                        VStack(spacing: 1) {              // ← ヘッダーとカードの間隔も詰める
                            // 時間ヘッダーを小さめにして上に寄せる
                            timeHeaderCompact(for: i)
                                .frame(height: timeHeaderH)

                            // 本体カード（計算した高さを必ず当てる）
                            miniCard(index: i,
                                    period: p,
                                    highlight: nowHere,
                                    height: cardH)
                            .frame(width: cellW, height: cardH)

                            // 現在コマの丸印
                            Circle()
                                .fill(nowHere ? Color.secondary : .clear)
                                .frame(width: dotH, height: dotH)
                        }
                        .frame(width: cellW)
                    }
                }
            }
            .padding(.horizontal, outerX)
            .padding(.top, -1)                             // ← さらに上詰め
            .padding(.bottom, 2)
        }
    }

    private func timeHeader(for index: Int) -> some View {
        let slot = PeriodTime.slots[index - 1]
        return VStack(spacing: 2) {
            Text(slot.start).font(.caption.monospacedDigit())
            Text("\(index)").font(.title3.weight(.bold))
            Text(slot.end).font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }
    // 追加：詰めた時間ヘッダー
    private func timeHeaderCompact(for index: Int) -> some View {
        let slot = PeriodTime.slots[index - 1]
        return VStack(spacing: -3) {
            Text(slot.start)
                .font(.system(size: WFont.timeSize, weight: .regular).monospacedDigit())
            Text("\(index)")
                .font(WFont.indexFont)
            Text(slot.end)
                .font(.system(size: WFont.timeSize, weight: .regular).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }


    @ViewBuilder
    private func miniCard(index: Int, period: WidgetPeriod?, highlight: Bool, height: CGFloat) -> some View {
        let title = period?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let room  = period?.room.trimmingCharacters(in: .whitespacesAndNewlines)  ?? ""
        let hasContent = !(title.isEmpty && room.isEmpty)
        // ★ ここで色を決定
        let baseUI = uiColor(for: period?.colorKey)
        let fillUI = highlight ? baseUI : pastel(baseUI)   // 現在コマは“そのままの色”、それ以外は淡く
        let fill = Color(uiColor: fillUI)

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hasContent ? fill : Color(.tertiarySystemFill))

            if hasContent {
                let bottomInset: CGFloat = 8       // 教室ラベルの下端余白
                let roomReserve: CGFloat = 18      // 教室ラベル分の“下の空き”を確保（被り防止）

                ZStack(alignment: .bottom) {
                    // ▼ 下端固定：教室名
                    Text(room.isEmpty ? " " : room)
                        .font(.system(size: WFont.roomSize, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .padding(.bottom, bottomInset)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // ▼ 中央固定：授業名（下にroomReserve分の作業領域を確保して中央寄せ）
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(title)
                            .font(.system(size: WFont.titleSize, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .minimumScaleFactor(0.82)
                            .padding(.horizontal, 10)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, roomReserve + bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .foregroundStyle(.black)
            }

            
            
        }
    }
    

    private func isNowSlot(_ index: Int) -> Bool {
        let slot = PeriodTime.slots[index - 1]
        let cal = Calendar.current
        let now = Date()
        func t(_ s: String) -> Date {
            var c = cal.dateComponents([.year,.month,.day], from: now)
            let p = s.split(separator: ":").map { Int($0) ?? 0 }
            c.hour = p[0]; c.minute = p[1]
            return cal.date(from: c)!
        }
        return (t(slot.start)...t(slot.end)).contains(now)
    }


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
            let rowSpacing: CGFloat = (rows >= 7 ? 2 : 4)

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
                    .font(WFont.weekdayFont)
                    .foregroundStyle(weekdayTint)

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

    // Large/共通：左側の時間・時限表示（09:00 / 1 / 10:30 の縦3段）
    @ViewBuilder
    private func timeTriad(start: String, period: Int, end: String) -> some View {
        VStack(spacing: 1) { // ← 2 → 1（キュッと詰める）
            Text(start)
                .font(.system(size: WFont.largeTimeSize, weight: .regular).monospacedDigit())
            Text("\(period)")
                .font(.system(size: WFont.largeIndexSize, weight: .semibold).monospacedDigit()) // ← 20pt → 16pt
            Text(end).font(.system(size: WFont.largeTimeSize, weight: .regular).monospacedDigit())
        }
        .frame(minWidth: 40)        // ← 48 → 40（左コラムを少し細く）
        .foregroundStyle(.primary)
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
        let title = period?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let room  = period?.room.trimmingCharacters(in: .whitespacesAndNewlines)  ?? ""
        let teacherName = teacher(of: period)
        let hasContent = !(title.isEmpty && room.isEmpty && teacherName.isEmpty)

        // miniCard と同じ色決定ロジック（現在コマは元色・それ以外は淡色）
        let baseUI = uiColor(for: period?.colorKey)
        let bgUI: UIColor = hasContent ? (highlight ? baseUI : pastel(baseUI)) : .tertiarySystemFill
        let fill = Color(uiColor: bgUI)

        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)

            HStack(spacing: 12) {
                // 左：統一フォーマット（09:00 / 1 / 10:30）
                timeTriad(start: start, period: index, end: end)
                    .frame(width: 48)

                // 中央：授業名 + サブ情報
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? " " : title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    HStack(spacing: 8) {
                        if !room.isEmpty { Text(room) }
                        if !teacherName.isEmpty { Text(teacherName) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: height)
        }
        // ★ 追加：カード内の左側に小さな丸を重ねる（今のコマだけ表示）
        .overlay(alignment: .leading) {
            Circle()
                .fill(highlight ? Color.secondary : .clear)
                .frame(width: 10, height: 10)   // 必要なら 8〜12 で微調整
                .padding(.leading, 6)           // 左端からのオフセット
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
                view.containerBackground(for: .widget) { widgetBGColor() }
            } else {
                view.background(widgetBGColor())
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

